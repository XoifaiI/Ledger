--!strict
--!optimize 2

--[=[
	Store: The store object that Ledger.New gives back.
	
	One store holds one datastore name. It owns each key under that name, and each session that is
	live on this server.
	The five requires with no name on them are what put the methods on the class. Core, Write, Read,
	Admin and Ops each write onto the table in Class, and this file requires all of them before it
	freezes that table. Nothing is copied across.
	The layers are put in order here. Escrow is present only when the store names a balance.
	Booking is next, then tally, then names outside all of them.
	A session with nothing queued and nothing parked reads on each fourth turn. An idle player
	therefore costs one request every two minutes.
	Each session waits a different amount before its first save. Many players who join together
	therefore spread their saves across the interval, and do not send them in one burst.
	
	Return type: A table with New.
	Example usage:
		local Store = require("./Store")
		local Bank = Store.New(Options)
--]=]

local Future = require("../Util/Future")
local Observer = require("../Util/Observer")
local SetInterval = require("../Util/SetInterval")
local TableUtil = require("../Util/TableUtil")
local Threads = require("../Util/Threads")
local DataStoreWrapper = require("../Util/DataStoreWrapper")
local Fault = require("../Contract/Fault")
local Reasons = require("../Contract/Reason")
local Contract = require("../Contract/Op")
local Public = require("../Contract/Public")
local Compact = require("../Record/Compact")
local Reconcile = require("../Record/Reconcile")
local Shape = require("../Record/Shape")
local Layer = require("../Kernel/Layer")
local Booking = require("../Feature/Booking")
local Escrow = require("../Feature/Escrow")
local Names = require("../Feature/Names")
local Tally = require("../Feature/Tally")
local Recovery = require("../Protocol/Recovery")
local Session = require("../Live/Session")
local Registry = require("./Registry")
local Store = require("./Class")
local Types = require("./Types")
local Write = require("./Write")

require("./Core")
require("./Read")
require("./Admin")
require("./Ops")

type Future<T...> = Future.Future<T...>
type Op = Contract.Op
type Reason = Reasons.Reason
type Migration = Contract.Migration
type Config<D> = Public.Config<D>
type TxLeg = Public.TxLeg
type Store = Types.Store

local Players = game:GetService("Players")

local AUTOSAVE_INTERVAL = Write.AUTOSAVE_INTERVAL
local IDLE_EVERY = 4
local MIN_WRITE_BUDGET = 4
local MIN_HEAVY_BUDGET = 1
local HEAVY_PENDING = 256

local RESET_KIND = "__Reset"

local UNRESOLVED = Reasons.Unresolved

local function MakeInitial(Default: any): any
	return TableUtil.DeepFreeze(TableUtil.DeepCopy(Default))
end

local function WrapSystem(GameReducer: Contract.Reducer<any>, Initial: any, Steps: { Migration }): Contract.Reducer<any>
	local Known = #Steps

	local function Combined(State: any, Op: Op): any?
		if Op.Kind ~= RESET_KIND then
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

		local Migrated = Shape.Migrate(Steps, TableUtil.DeepCopy(Snapshot), Version)
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

local function New<D>(Config: Config<D>): Public.Store<D>
	assert(
		not Registry.Claimed[Config.Name] and not Registry.Claimed[`{Config.Name}_Tx`],
		`a store named '{Config.Name}' already exists in this server`
	)
	Registry.Claimed[Config.Name] = true
	Registry.Claimed[`{Config.Name}_Tx`] = true

	if DataStoreWrapper.Swapped() then
		warn(`Ledger: store '{Config.Name}' is on a fake datastore, nothing it saves outlives this server. Ledger.UseReal() puts it back`)
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

	local Body: Types.Fields = {
		Options = Config :: any,
		Reducer = WrapSystem(Base, Initial, Steps),
		Wrapper = DataStoreWrapper.New(Config.Name),
		TxWrapper = DataStoreWrapper.New(`{Config.Name}_Tx`),
		Initial = Initial,
		Migrations = Steps,
		Handles = Handled,
		Books = nil,
		Shaped = nil,
		Keys = (Config.Keys or "Player") :: Contract.KeysMode,
		Loaded = {},
		Waiters = {},
		Loads = {},
		Saving = {},
		Staleness = Observer.New(true) :: Observer.Subject<string>,
		Meter = { Skipped = 0, At = 0, Records = 0, Markers = 0, Swollen = 0, Said = 0 },
		ReapAt = "",
		Closed = false
	}
	local Built: Store = setmetatable(Body :: any, Store) :: any

	table.insert(Registry.Stores, Built)
	return Built :: any
end

function Store.Wake(self: Store, UserId: number, Active: any?)
	local List = self.Waiters[UserId]
	if List == nil then
		return
	end
	self.Waiters[UserId] = nil
	for _, Thread in List do
		Threads.Resume(Thread, Active)
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
		Fault.Holds(
			(Entry.Active :: any) ~= (Active :: any),
			`the session for {UserId} is being saved on the way out while the store still lists it as live`
		)
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
		Registry.Sweep():Add(self, tostring(UserId))
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

	Fault.Holds(self.Loaded[UserId] == nil, `{Player.Name} is starting a load while they already have a live session, so two sessions would write the same key`)
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

	Fault.Holds(self.Loads[UserId] == nil, "a load finished while this player was still marked as loading")

	self.Loaded[UserId] = {
		Active = Active,
		Ticks = 0,
		Ticker = SetInterval(AUTOSAVE_INTERVAL, function()
			self:Autosave(UserId)
		end, math.random() * AUTOSAVE_INTERVAL)
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
	task.cancel(Entry.Ticker)

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

	for Index, Known in Registry.Stores do
		if Known == self then
			table.remove(Registry.Stores, Index)
			break
		end
	end
	Registry.Claimed[self.Options.Name] = nil
	Registry.Claimed[`{self.Options.Name}_Tx`] = nil
	Registry.Sweep():Forget(self)
	self.Staleness:Destroy()

	local Jobs: { Future<boolean, Reason?> } = {}
	for UserId, Entry in self.Loaded do
		self.Loaded[UserId] = nil
		task.cancel(Entry.Ticker)
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
	New = New
})
