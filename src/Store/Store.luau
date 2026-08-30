--!strict
--!optimize 2

--[=[

	Store: The store object that Ledger.New gives back.

	One store holds one datastore name, every key under it, and every session live on this server. It
	builds the reducer stack, loads and unloads players, and runs an autosave for each session. The
	five requires with no name on them put the rest of the methods onto the class.

	Return type: A table with New.
	Example usage:
		local Store = require("./Store")
		local Bank = Store.New(Options)
--]=]

local Future = require("../Util/Future")
local Observer = require("../Util/Observer")
local Clock = require("../Util/Clock")
local SetInterval = require("../Util/SetInterval")
local TableUtil = require("../Util/TableUtil")
local Roblox = require("../Hooks/Roblox")
local DataStoreWrapper = require("../Util/DataStoreWrapper")
local Ids = require("../Encode/Ids")
local Windows = require("../Core/Constants/Windows")
local Reasons = require("../Core/Constants/Reasons")
local Kinds = require("../Core/Constants/Kinds")
local Shapes = require("../Core/Shapes")
local Api = require("../Core/Api")
local Compact = require("../Record/Compact")
local Reconcile = require("../Record/Reconcile")
local Schema = require("../Record/Schema")
local Layer = require("../Layers/Layer")
local Booking = require("../Layers/Booking")
local Escrow = require("../Layers/Escrow")
local Names = require("../Layers/Names")
local Tally = require("../Layers/Tally")
local Recovery = require("../Protocol/Recovery")
local Session = require("../Session/Session")
local Registry = require("./Registry")
local Store = require("./Class")
local Types = require("./Types")
local Write = require("./Api/Write")

require("./Shared")
require("./Api/Read")
require("./Api/Admin")
require("./Api/Ops")

type Future<T...> = Future.Future<T...>
type Op = Shapes.Op
type Reason = Reasons.Reason
type Migration = Shapes.Migration
type Config<D> = Api.Config<D>
type TxLeg = Api.TxLeg
type Store = Types.Store<any>

local Players = game:GetService("Players")

local IDLE_EVERY = 4
local MIN_WRITE_BUDGET = 4
local MIN_HEAVY_BUDGET = 1
local HEAVY_PENDING = 256

local TX_SUFFIX = "_Tx"

local UNRESOLVED = Reasons.Unresolved

local function MakeInitial(Default: any): any
	return TableUtil.DeepFreeze(TableUtil.DeepCopy(Default))
end

local function WrapSystem(GameReducer: Shapes.Reducer<any>, Initial: any, Steps: { Migration }): Shapes.Reducer<any>
	local Known = #Steps

	local function Combined(State: any, Op: Op): any?
		if Op.Kind ~= Kinds.RESET then
			return GameReducer(State, Op)
		end

		local Snapshot = Op.State
		if type(Snapshot) ~= "table" then
			return nil
		end

		local Version = if type(Op.Version) == "number" then Op.Version else 0
		local Floor = if type(Op.Floor) == "number" then Op.Floor else Version
		if Version > Known and Floor > Known then
			return nil
		end

		local Migrated = Schema.Migrate(Steps, TableUtil.DeepCopy(Snapshot), Version)
		if Migrated == nil then
			return nil
		end

		local Next = Reconcile(Initial, Migrated)
		Next._Received = State._Received
		Next._Held = State._Held
		return Next
	end

	return Combined
end

local function New<D>(Config: Config<D>): Api.Store<D>
	local Marked = `{Config.Name}{TX_SUFFIX}`
	assert(not Registry.Claimed[Config.Name] and not Registry.Claimed[Marked], `a store named '{Config.Name}' already exists in this server`)
	Registry.Claimed[Config.Name] = true
	Registry.Claimed[Marked] = true

	local Turn = Clock.Held()
	local Asked = Config.Mock
	local Hook = Config.Hook or (if Asked then Registry.Mock(if type(Asked) == "table" then Asked else nil) else Registry.Defaults.Hook)
	if Hook ~= Roblox.New() then
		warn(`Ledger: store '{Config.Name}' is on a fake datastore, nothing it saves outlives this server`)
	end

	local Layers: { Layer.Layer } = {}
	for _, Feature in { Escrow.Layered, Booking.Layered, Tally.Layered } do
		local Made = Feature(Config.Balance)
		if Made ~= nil then
			table.insert(Layers, Made)
		end
	end

	local Base = Names.Wrap(Layer.Stack(Layers, Config.Reducer :: any))
	local Handled = Layer.Handles(Layers)

	local Initial = MakeInitial(Config.Default)
	local Steps: { Migration } = Config.Migrations or {}

	local Body: Types.Fields<D> = {
		Options = Config :: any,
		Reducer = WrapSystem(Base, Initial, Steps),
		Wrapper = DataStoreWrapper.New(Config.Name, Turn, Hook),
		TxWrapper = DataStoreWrapper.New(Marked, Turn, Hook),
		Initial = Initial,
		Migrations = Steps,
		Handles = Handled,
		Books = nil,
		Shaped = nil,
		Keys = (Config.Keys or "Player") :: Shapes.KeysMode,
		Loaded = {},
		Waiters = {},
		Loads = {},
		Saving = {},
		Node = Ids.Home(),
		Sweep = Registry.Sweep(),
		Sweeping = nil,
		Staleness = Observer.New(true) :: Observer.Subject<string>,
		Meter = { Skipped = 0, At = 0, Records = 0, Markers = 0, Swollen = 0, Said = 0 },
		Resume = nil,
		Closed = false,
	}
	local Built = setmetatable(Body, Store)

	table.insert(Registry.Stores, Built)
	Built.Sweep:Adopt(Built:Swept())
	return Built
end

function Store.Wake(self: Store, UserId: number, Active: any?)
	local List = self.Waiters[UserId]
	if List == nil then
		return
	end
	self.Waiters[UserId] = nil
	for _, Thread in List do
		self.Wrapper.Scheduler.Resume(Thread, Active)
	end
end

function Store.Handled(self: Store, Player: Player, Why: Reason): boolean
	local Answer = self.Options.OnLoadFailed
	if Answer == nil then
		return false
	end

	local Ok, Took = pcall(Answer, Player, Why)
	if not Ok then
		warn(`Ledger: OnLoadFailed threw for {Player.Name}, so they get kicked as if it had said no: {Took}`)
		return false
	end
	if Took ~= true then
		return false
	end

	if Player.Parent ~= nil and Players:GetPlayerByUserId(Player.UserId) ~= nil then
		warn(`Ledger: OnLoadFailed said it handled {Player.Name} after a '{Why}' load but they are still in the server with no data. send them somewhere or kick them`)
	end
	return true
end

function Store.Autosave(self: Store, UserId: number)
	local Entry = self.Loaded[UserId]
	if Entry == nil then
		return
	end

	local Active = Entry.Active
	local Writing = #Active.Pending > 0 or Compact.Oversized(Active.LogSize, Active.LogBytes, Active.StateBytes)

	Entry.Ticks += 1
	if not Writing and Active.Parked == 0 and Entry.Ticks % IDLE_EVERY ~= 0 then
		return
	end

	local Pool = if Writing then Enum.DataStoreRequestType.UpdateAsync else Enum.DataStoreRequestType.GetAsync

	local Floor = if #Active.Pending >= HEAVY_PENDING then MIN_HEAVY_BUDGET else MIN_WRITE_BUDGET
	if self.Wrapper:Budget(Pool) < Floor then
		self:Starved(Pool)
		return
	end

	local Ok = Entry.Active:Flush():Wait()
	if Ok and Compact.Oversized(Entry.Active.LogSize, Entry.Active.LogBytes, Entry.Active.StateBytes) then
		Ok = Entry.Active:Compact():Wait()
	end
	if Ok then
		return
	end
	warn(`Ledger: the autosave for {UserId} keeps failing, the datastore is probably down`)
end

function Store.Save(self: Store, Active: any): Future<boolean, Reason?>
	for UserId, Entry in self.Loaded do
		assert((Entry.Active :: any) ~= (Active :: any), `the session for {UserId} is being saved on the way out while the store still lists it as live`)
	end

	local Job = Active:Release()
	self.Saving[Job] = true
	task.spawn(function()
		Job:Wait()
		self.Saving[Job] = nil
	end)
	return Job
end

function Store.PickUp(self: Store, Active: any, UserId: number)
	if Active.Landed ~= nil then
		self.Sweep:Add(self:Swept(), tostring(UserId))
	end

	local Held = Active:Get()._Held
	if not TableUtil.Occupied(Held) then
		return
	end

	local Records, Format = self:Records(), self:Format()
	task.spawn(function()
		local Ok, Reason = pcall(Recovery.Transfers, Records, Format, UserId, Held)
		if not Ok then
			Write.Failed("pick up the unfinished transfers on", tostring(UserId), Reason)
		end
	end)
end

function Store.Load(self: Store, Player: Player)
	self:ExpectPlayers("Load")
	local UserId = Player.UserId

	if self.Loaded[UserId] ~= nil then
		warn(`Ledger: {Player.Name} already has a live session, ignoring this second Load`)
		return
	end
	if self.Loads[UserId] == "Loading" then
		warn(`Ledger: {Player.Name} is already loading, ignoring this second Load`)
		return
	end

	assert(self.Loaded[UserId] == nil, `{Player.Name} is starting a load while they already have a live session, so two sessions would write the same key`)
	self.Loads[UserId] = "Loading"

	local Job = Session.Load(self:Records(), self:Format(), tostring(UserId), self.TxWrapper)
	local Active, Why = Job:Wait()

	local Left = self.Loads[UserId] == "Leaving"
	self.Loads[UserId] = nil

	if Active == nil then
		self:Wake(UserId, nil)
		if not self:Handled(Player, Why or UNRESOLVED) then
			Player:Kick("Your data failed to load, please rejoin")
		end
		return
	end

	if self.Loaded[UserId] ~= nil then
		warn(`Ledger: {Player.Name} was loaded twice concurrently, dropping the duplicate session`)
		Active:Release()
		return
	end

	local Stopping = self.Closed or Registry.Shutting.Now
	if Left or Stopping or not Player.Parent then
		if not Stopping then
			self:PickUp(Active, UserId)
		end
		self:Save(Active)
		self:Wake(UserId, nil)
		return
	end

	assert(self.Loads[UserId] == nil, "a load finished while this player was still marked as loading")

	self.Loaded[UserId] = {
		Active = Active,
		Ticks = 0,
		Ticker = SetInterval(self.Wrapper.Scheduler, Windows.AUTOSAVE, function()
			self:Autosave(UserId)
		end, math.random() * Windows.AUTOSAVE),
	}
	self:Wake(UserId, Active)
	self:PickUp(Active, UserId)
end

function Store.Unload(self: Store, Player: Player)
	self:ExpectPlayers("Unload")
	local UserId = Player.UserId
	local Entry = self.Loaded[UserId]

	if Entry == nil then
		if self.Loads[UserId] ~= nil then
			self.Loads[UserId] = "Leaving"
		end
		self:Wake(UserId, nil)
		return
	end

	self.Loaded[UserId] = nil
	self.Wrapper.Scheduler.Cancel(Entry.Ticker)

	local Job = self:Save(Entry.Active)
	Job:Wait()
	self.Saving[Job] = nil
end

function Store.Get(self: Store, Player: Player): any?
	self:ExpectPlayers("Get")
	local Entry = self.Loaded[Player.UserId]
	return if Entry then Entry.Active else nil
end

function Store.Expect(self: Store, Player: Player): any
	self:ExpectPlayers("Expect")
	local Entry = self.Loaded[Player.UserId]
	return assert(Entry and Entry.Active, `data for {Player.Name} is not loaded`)
end

function Store.IsLoaded(self: Store, Player: Player): boolean
	self:ExpectPlayers("IsLoaded")
	return self.Loaded[Player.UserId] ~= nil
end

function Store.WaitForLoaded(self: Store, Player: Player): any?
	self:ExpectPlayers("WaitForLoaded")
	local Entry = self.Loaded[Player.UserId]
	if Entry ~= nil then
		return Entry.Active
	end
	if not Player.Parent then
		return nil
	end

	local List = self.Waiters[Player.UserId]
	if List == nil then
		List = {}
		self.Waiters[Player.UserId] = List
	end
	table.insert(List, coroutine.running())
	return coroutine.yield()
end

function Store.Read(self: Store, Player: Player): any
	self:ExpectPlayers("Read")
	local Entry = self.Loaded[Player.UserId]
	return if Entry then Entry.Active:Get() else nil
end

function Store.Destroy(self: Store)
	if self.Closed then
		return
	end
	self.Closed = true

	local Listed = table.find(Registry.Stores, self)
	if Listed ~= nil then
		table.remove(Registry.Stores, Listed)
	end
	Registry.Claimed[self.Options.Name] = nil
	Registry.Claimed[`{self.Options.Name}{TX_SUFFIX}`] = nil
	self.Sweep:Forget(self:Swept())
	self.Staleness:Destroy()

	local Jobs: { Future<boolean, Reason?> } = {}
	for UserId, Entry in self.Loaded do
		self.Loaded[UserId] = nil
		self.Wrapper.Scheduler.Cancel(Entry.Ticker)
		table.insert(Jobs, self:Save(Entry.Active))
	end

	for UserId in self.Waiters do
		self:Wake(UserId, nil)
	end
	table.clear(self.Loads)

	for _, Job in Jobs do
		Job:Wait()
		self.Saving[Job] = nil
	end
end

table.freeze(Store)

return table.freeze({
	New = New,
})
