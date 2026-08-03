--!strict
--!optimize 2

-- the store object Ledger.New hands back. one per datastore name, owning every key under it and every session live on this server. the datastore budget belongs to the whole server, so when it runs short the sessions holding the most unsaved work save first

local Players = game:GetService("Players")

local Future = require("../Util/Future")
local SetInterval = require("../Util/SetInterval")
local TableUtil = require("../Util/TableUtil")
local Threads = require("../Util/Threads")
local DataStoreWrapper = require("../Util/DataStoreWrapper")
local Clock = require("../Clock")
local Fault = require("../Fault")
local Dedupe = require("../Record/Dedupe")
local Log = require("../Record/Log")
local MakeOp = require("../Record/MakeOp")
local IsStorable = require("../Record/Storable")
local Reconcile = require("../Record/Reconcile")
local Mark = require("../Mark")
local Reasons = require("../Reason")
local Session = require("../Session")
local Transfer = require("../Transfer")
local Tx = require("../Tx")
local Types = require("../Types")
local Registry = require("./Registry")

type Future<T...> = Future.Future<T...>
type Op = Types.Op
type Reason = Types.Reason
type KeyLike = Types.KeyLike
type TxLeg = Types.TxLeg
type Config<D> = Types.Config<D>
type Record = Types.Record<any>
type Session<S> = Types.Session<S>
type Store<D> = Types.Store<D>
type Migration = Types.Migration
type DataStoreImpl = Types.DataStoreImpl
type DataStore = Types.DataStore

type Allow = (Record) -> boolean
type LegTarget = { Store: DataStore, Key: string }

local AUTOSAVE_INTERVAL = 30
local MIN_WRITE_BUDGET = 4
local MIN_HEAVY_BUDGET = 1
local HEAVY_PENDING = 256

local MAX_KEY = 50
local MAX_TRANSFER_ID = 64
local MAX_TX_ID = 50

local RESET_KIND = "__Reset"

local REFUSED = Reasons.Refused
local INVALID = Reasons.Invalid
local UNRESOLVED = Reasons.Unresolved
local BUSY = Reasons.Busy
local CLOSED = Reasons.Closed
local BEHIND = Reasons.Behind
local FULL = Reasons.Full

local function Failed(What: string, Key: string, Err: any): Reason
	local Why = Fault.Named(Err)
	if Why == CLOSED then
		return Why
	end

	if Why == BEHIND then
		warn(`Ledger: could not {What} '{Key}', a newer server wrote it and this one cannot read that yet. finish the deploy: {Err}`)
		return Why
	end

	warn(`Ledger: could not {What} '{Key}': {Err}`)
	return Why
end

local function ValidId(UserId: any): boolean
	return type(UserId) == "number" and UserId == UserId // 1 and UserId > 0 and UserId < math.huge
end

local function Rejected(Why: Reason?): Future<boolean, Reason?>
	return Future.Completed(false, Why)
end

local function MakeInitial(Default: any): any
	return TableUtil.DeepFreeze(TableUtil.DeepCopy(Default))
end

local function WrapSystem(GameReducer: Types.Reducer<any>, Initial: any, Steps: { Types.Migration }): Types.Reducer<any>
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

		local Migrated = Log.Migrate(Steps, TableUtil.DeepCopy(Snapshot), Version)
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

local DataStore = {} :: DataStoreImpl
DataStore.__index = DataStore

local function LegStore(Coordinator: DataStore, Index: number, Leg: TxLeg): DataStore
	if Leg.Store == nil then
		return Coordinator
	end

	assert(
		getmetatable(Leg.Store :: any) == DataStore,
		`Tx leg {Index} names a Store that was not built by Ledger.New`
	)
	return Leg.Store :: any
end

local function LegStorable(Leg: TxLeg): (boolean, string?)
	local Probe: { [any]: any } = if Leg.Fields then table.clone(Leg.Fields) else {}
	Probe.Id = "probe"
	Probe.Kind = Leg.Kind

	return IsStorable.Op(Probe)
end

local function MapLeg(
	Coordinator: DataStore,
	Index: number,
	Leg: TxLeg,
	Touched: { [string]: boolean }
): (Tx.Leg, LegTarget)
	assert(type(Leg) == "table", `Tx leg {Index} is not a table`)
	assert(type(Leg.Kind) == "string" and #Leg.Kind > 0, `Tx leg {Index} needs a non-empty string Kind`)
	assert(Leg.Fields == nil or type(Leg.Fields) == "table", `Tx leg {Index} Fields must be a table when given`)
	assert(
		Leg.Fields == nil or (Leg.Fields :: any).Once == nil,
		`Tx leg {Index} carries Once, but the transaction Id already makes every leg land at most once. drop it`
	)

	local Target = LegStore(Coordinator, Index, Leg)
	local Raw = if Target.Keys == "Player" then Leg.UserId else Leg.Key
	local Resolved = Target:KeyFor(Raw)
	assert(Resolved, `Tx leg {Index} needs {Target:KeyIssue()}`)

	local Mark = Target:Mark(Resolved)
	assert(not Touched[Mark], `Tx leg {Index} touches '{Resolved}' twice, a transaction may only touch a key once per store`)
	Touched[Mark] = true

	return {
		Key = Resolved,
		Kind = Leg.Kind,
		Fields = Leg.Fields,
		Log = Target:Records(),
		Shape = Target:Format(),
		TxStore = Target.TxWrapper
	}, { Store = Target, Key = Resolved }
end

local function HeldOn(Store: DataStore, Key: string): (boolean, any)
	return pcall(function(): any
		return Store:Fold(Store:ReadRecord(Key))._Held
	end)
end

local function CountHeld(Held: any): (number, number)
	if type(Held) ~= "table" then
		return 0, 0
	end

	local Holds, Amount = 0, 0
	for _, Entry in Held do
		if type(Entry) == "table" and type(Entry.Amount) == "number" then
			Holds += 1
			Amount += Entry.Amount
		end
	end
	return Holds, Amount
end

local function HandOver(Store: DataStore, Key: string): (number, number)
	local Read, Held = HeldOn(Store, Key)
	if not Read then
		warn(`Ledger: could not check '{Key}' for unfinished transfers before erasing it, so any money still being sent is gone for good: {Held}`)
		return 0, 0
	end
	if not TableUtil.Occupied(Held) then
		return 0, 0
	end

	local Sent, Why = pcall(function()
		Transfer.Recover(Store:Records(), Store:Format(), Key, Held)
	end)
	if not Sent then
		warn(`Ledger: could not hand over the transfers set aside on '{Key}' before erasing it, they are counted below: {Why}`)
	end

	local Again, Left = HeldOn(Store, Key)
	if not Again then
		warn(`Ledger: could not check '{Key}' again after finishing its transfers, so anything still being sent is gone for good: {Left}`)
		return 0, 0
	end
	return CountHeld(Left)
end

function DataStore.Mark(self: DataStore, Key: string): string
	return Mark.Of(self.Wrapper.Name, Key)
end

function DataStore.KeyFor(self: DataStore, Value: any): string?
	if self.Keys == "Player" then
		return if ValidId(Value) then tostring(Value) else nil
	end
	return if type(Value) == "string" and #Value > 0 and #Value <= MAX_KEY and utf8.len(Value) ~= nil
		then Value
		else nil
end

function DataStore.KeyIssue(self: DataStore): string
	return if self.Keys == "Player"
		then "a positive integer UserId"
		else `a key string of 1 to {MAX_KEY} characters`
end

function DataStore.Live(self: DataStore, What: string)
	assert(not self.Closed, `{What} was called on '{self.Options.Name}' after it was destroyed, build a new store with Ledger.New`)
end

function DataStore.Resolve(self: DataStore, Key: KeyLike, What: string): string
	self:Live(What)
	local Resolved = self:KeyFor(Key)
	assert(Resolved, `{What} needs {self:KeyIssue()}, got {typeof(Key)}`)
	return Resolved
end

function DataStore.ExpectPlayers(self: DataStore, What: string)
	self:Live(What)
	assert(self.Keys == "Player", `{What} is for player stores, '{self.Options.Name}' uses string keys`)
end

function DataStore.ExpectBalance(self: DataStore, What: string)
	assert(self.Options.Balance, `{What} needs the store to name a Balance field, like Balance = "Gold"`)
end

function DataStore.Records(self: DataStore): Log.Log
	return Log.New(self.Wrapper)
end

function DataStore.Format(self: DataStore): Log.Shape<any>
	return Log.Shape(self.Reducer, self.Initial, self.Migrations)
end

function DataStore.Fold(self: DataStore, Record: Record): any
	return self:Format():Fold(Record)
end

function DataStore.ReadRecord(self: DataStore, Key: string): Record
	return self:Records():Read(Key)
end

function DataStore.Watch(self: DataStore, Key: string, Record: Record)
	if Log.HasPending(Record) then
		Registry.Sweep:Add(self, Key)
	end
end

function DataStore.WatchHeld(self: DataStore, Key: string, State: any)
	local Held = if type(State) == "table" then State._Held else nil
	if TableUtil.Occupied(Held) then
		Registry.Sweep:Add(self, Key)
	end
end

function DataStore.ReapMarkers(self: DataStore): number
	local Name = self.Wrapper.Name

	local Ok, Reaped = pcall(function(): number
		return Tx.Reap(self.TxWrapper, function(Store: string): Log.Log?
			for _, Known in Registry.Stores do
				if Known.Wrapper.Name == Store then
					return Known:Records()
				end
			end
			return nil
		end)
	end)
	if Ok then
		return Reaped
	end

	warn(`Ledger: could not tidy up the transaction markers for '{Name}', so they wait for the next pass: {Reaped}`)
	return 0
end

function DataStore.Repair(self: DataStore, Key: string): (boolean, boolean)
	local Record = Tx.Settle(self:Records(), self.TxWrapper, Key, self:ReadRecord(Key))
	if Log.HasPending(Record) then
		return false, false
	end

	local Held = self:Fold(Record)._Held
	if not TableUtil.Occupied(Held) then
		return true, false
	end

	return Transfer.Recover(self:Records(), self:Format(), Key, Held)
end

function DataStore.Wake(self: DataStore, UserId: number, Active: Session<any>?)
	local List = self.Waiters[UserId]
	if List == nil then
		return
	end
	self.Waiters[UserId] = nil
	for _, Thread in List do
		Threads.Resume(Thread, Active)
	end
end

function DataStore.Append(self: DataStore, Key: string, Op: Op, Guard: Allow?): Record
	if Guard == nil then
		return self:Records():Append(Key, { Op })
	end
	return self:Records():Append(Key, { Op }, Guard)
end

function DataStore.Maintain(self: DataStore, Key: string, Record: Record): Record
	local Settled = Record
	if Log.HasPending(Record) then
		local Ok, Resolution = pcall(function(): Record
			return Tx.Settle(self:Records(), self.TxWrapper, Key, Record)
		end)
		if Ok then
			Settled = Resolution
		else
			warn(`Ledger: could not settle a pending transaction leg on '{Key}' during a write, so it stays pending: {Resolution}`)
		end
	end

	self:Watch(Key, Settled)
	local Trimmed = self:Records():Trim(Key, self:Format(), Settled)
	if Log.HasPending(Trimmed) and Log.Overgrown(Trimmed) then
		self:Swelling(Key, Trimmed)
	end
	return Settled
end

function DataStore.Written(self: DataStore, Key: string, Op: Op, What: string, Guard: Allow?, Denied: Reason?): (boolean, Reason?)
	local Landed, Result = pcall(function(): Record
		return self:Append(Key, Op, Guard)
	end)

	if not Landed then
		local Named = Fault.Named(Result)
		if Named == CLOSED then
			return false, CLOSED
		end
		if Named == BEHIND then
			warn(`Ledger: {What} on '{Key}' was not written, a newer server wrote that record and this one cannot read it yet. finish the deploy: {Result}`)
			return false, BEHIND
		end
		if Named == FULL then
			warn(`Ledger: {What} on '{Key}' was not written, that key is carrying more unsaved ops than it can hold: {Result}`)
			return false, FULL
		end

		warn(`Ledger: {What} on '{Key}' could not be written, though it might still have gone through: {Result}`)
		return false, UNRESOLVED
	end

	local Stored: Record = Result
	if Guard ~= nil and not Guard(Stored) then
		return false, Denied or REFUSED
	end

	local Ok, Why = pcall(function(): Reason?
		local Settled = self:Maintain(Key, Stored)
		if not Log.Holds(Settled, Op.Id) then
			return UNRESOLVED
		end

		local Took, Sure = self:Format():Certain(Settled, Op.Id)
		assert(
			Sure or Log.HasPending(Settled),
			`the answer for {What} on '{Key}' is unsure while nothing is pending there, so a settled key is reporting doubt`
		)
		if not Sure then
			return UNRESOLVED
		end
		return if Took then nil else REFUSED
	end)

	if not Ok then
		warn(`Ledger: {What} on '{Key}' went into the log, but this server could not read the record back to say what it folded to: {Why}`)
		return false, UNRESOLVED
	end
	return Why == nil, Why
end

function DataStore.Swelling(self: DataStore, Key: string, Record: Record)
	local Meter = self.Meter
	Meter.Swollen += 1

	local Now = Clock.Now()
	if Now - Meter.Said < AUTOSAVE_INTERVAL then
		return
	end

	local Blocking = "a transaction"
	for Txid in Log.PendingTx(Record) do
		Blocking = `transaction '{Txid}'`
		break
	end

	warn(
		`Ledger: '{Key}' is carrying {#Record.Ops} ops it cannot compact away because {Blocking} is still parked on it, so the record keeps growing until that settles. {Meter.Swollen} write(s) since the last of these`
	)

	Meter.Swollen = 0
	Meter.Said = Now
end

function DataStore.Starved(self: DataStore, Pool: Enum.DataStoreRequestType)
	local Meter = self.Meter
	Meter.Skipped += 1

	local Now = Clock.Now()
	if Now - Meter.At < AUTOSAVE_INTERVAL then
		return
	end

	local Records = self.Wrapper.Spent - Meter.Records
	local Markers = self.TxWrapper.Spent - Meter.Markers

	warn(
		`Ledger: {Meter.Skipped} autosave(s) skipped on '{self.Options.Name}' with {Pool.Name} budget at {self.Wrapper:Budget(Pool)}, so unsaved ops are piling up. this server spent {Records} request(s) on records and {Markers} on transaction markers since the last of these`
	)

	Meter.Skipped = 0
	Meter.At = Now
	Meter.Records = self.Wrapper.Spent
	Meter.Markers = self.TxWrapper.Spent
end

function DataStore.Autosave(self: DataStore, UserId: number)
	local Entry = self.Loaded[UserId]
	if Entry == nil then
		return
	end

	local Active = Entry.Active
	local Writing = #Active.Pending > 0 or Log.Oversized(Active.LogSize, Active.LogBytes)
	local Pool = if Writing then Enum.DataStoreRequestType.UpdateAsync else Enum.DataStoreRequestType.GetAsync

	local Floor = if #Active.Pending >= HEAVY_PENDING then MIN_HEAVY_BUDGET else MIN_WRITE_BUDGET
	if self.Wrapper:Budget(Pool) < Floor then
		self:Starved(Pool)
		return
	end

	local Ok = Entry.Active:Flush():Wait()
	if Ok and Log.Oversized(Entry.Active.LogSize, Entry.Active.LogBytes) then
		Ok = Entry.Active:Compact():Wait()
	end
	if Ok then
		return
	end
	warn(`Ledger: the autosave for {UserId} keeps failing, the datastore is probably down`)
end

function DataStore.Save(self: DataStore, Active: Session<any>): Future<boolean, Reason?>
	for UserId, Entry in self.Loaded do
		assert(
			(Entry.Active :: any) ~= (Active :: any),
			`the session for {UserId} is being saved on the way out while the store still lists it as live`
		)
	end

	local Job = Active:Release()
	self.Saving[Job] = true
	return Job
end

function DataStore.Buried(self: DataStore, Key: string, Replaced: Record)
	local Ok, State = pcall(function(): any
		return self:Fold(Replaced)
	end)
	if not Ok then
		warn(`Ledger: erased '{Key}' but could not read back what was on it, so this cannot say what went with it: {State}`)
		return
	end
	if type(State) ~= "table" then
		return
	end

	local Field = self.Options.Balance
	if Field == nil then
		return
	end

	local Balance = (State :: any)[Field]
	if type(Balance) ~= "number" or Balance <= 0 then
		return
	end

	warn(
		`Ledger: erasing '{Key}' destroyed {Balance} {Field}. anything sent to it for the next {Transfer.TOMB_HORIZON // 86400} days is turned away and given back to whoever sent it`
	)
end

function DataStore.Handled(self: DataStore, Player: Player, Why: Reason): boolean
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

function DataStore.Load(self: DataStore, Player: Player)
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

	if Left or self.Closed or Registry.Shutting.Now or not Player.Parent then
		self:Save(Active)
		self:Wake(UserId, nil)
		return
	end

	assert(self.Loads[UserId] == nil, "a load finished while this player was still marked as loading")

	self.Loaded[UserId] = {
		Active = Active,
		Ticker = SetInterval(AUTOSAVE_INTERVAL, function()
			self:Autosave(UserId)
		end)
	}
	self:Wake(UserId, Active)

	if Active.Landed ~= nil then
		Registry.Sweep:Add(self, tostring(UserId))
	end

	local Held = Active:Get()._Held
	if TableUtil.Occupied(Held) then
		local Records, Format = self:Records(), self:Format()
		task.spawn(function()
			local Ok, Why = pcall(Transfer.Recover, Records, Format, UserId, Held)
			if not Ok then
				Failed("pick up the unfinished transfers on", tostring(UserId), Why)
			end
		end)
	end
end

function DataStore.Unload(self: DataStore, Player: Player)
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

function DataStore.Get(self: DataStore, Player: Player): Session<any>?
	self:ExpectPlayers("Get")
	local Entry = self.Loaded[Player.UserId]
	return if Entry then Entry.Active else nil
end

function DataStore.Expect(self: DataStore, Player: Player): Session<any>
	self:ExpectPlayers("Expect")
	local Entry = self.Loaded[Player.UserId]
	return assert(Entry and Entry.Active, `data for {Player.Name} is not loaded`)
end

function DataStore.IsLoaded(self: DataStore, Player: Player): boolean
	self:ExpectPlayers("IsLoaded")
	return self.Loaded[Player.UserId] ~= nil
end

function DataStore.WaitForLoaded(self: DataStore, Player: Player): Session<any>?
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

function DataStore.Read(self: DataStore, Player: Player): any
	self:ExpectPlayers("Read")
	local Entry = self.Loaded[Player.UserId]
	return if Entry then Entry.Active:Get() else nil
end

function DataStore.Peek(self: DataStore, Key: KeyLike): Future<any?, Reason?>
	local Resolved = self:Resolve(Key, "Peek")

	return Future.New(function(): (any?, Reason?)
		local Ok, State = pcall(function(): any
			local Record = self:ReadRecord(Resolved)
			self:Watch(Resolved, Record)

			local Folded = self:Fold(Record)
			self:WatchHeld(Resolved, Folded)
			return Folded
		end)
		if not Ok then
			return nil, Failed("read", Resolved, State)
		end
		return State, nil
	end)
end

function DataStore.DidApply(self: DataStore, Key: KeyLike, Id: string): Future<boolean?, Reason?>
	local Resolved = self:Resolve(Key, "DidApply")
	assert(type(Id) == "string" and #Id > 0, "DidApply needs the same Once name the op was written under")

	return Future.New(function(): (boolean?, Reason?)
		local Ok, Applied = pcall(function(): boolean
			local State: any = self:Fold(self:ReadRecord(Resolved))
			return Dedupe.Has(State._Received, Dedupe.ONCE, Id)
		end)
		if not Ok then
			return nil, Failed(`check what has been applied to`, Resolved, Applied)
		end
		return Applied, nil
	end)
end

function DataStore.History(self: DataStore, Key: KeyLike, Limit: number?): Future<{ Types.HistoryEntry }?, Reason?>
	local Resolved = self:Resolve(Key, "History")
	local Page = math.clamp(if type(Limit) == "number" then Limit else 25, 1, 100)

	return Future.New(function(): ({ Types.HistoryEntry }?, Reason?)
		local Ok, Rows = pcall(function(): { Types.HistoryEntry }
			local Fine, Pages = self.Wrapper:ListVersionsAsync(Resolved, Enum.SortDirection.Descending, nil, nil, Page)
			if not Fine then
				error(Pages)
			end

			local Out: { Types.HistoryEntry } = {}
			for _, Info in (Pages :: DataStoreVersionPages):GetCurrentPage() do
				local Version = Info :: DataStoreObjectVersionInfo
				table.insert(Out, { Version = Version.Version, At = Version.CreatedTime / 1000, Deleted = Version.IsDeleted })
			end
			return Out
		end)
		if not Ok then
			return nil, Failed("list the history for", Resolved, Rows)
		end
		return Rows, nil
	end)
end

function DataStore.PeekVersion(self: DataStore, Key: KeyLike, Version: string): Future<any?, Reason?>
	local Resolved = self:Resolve(Key, "PeekVersion")
	assert(type(Version) == "string" and #Version > 0, "PeekVersion needs a Version string from History")

	return Future.New(function(): (any?, Reason?)
		local Ok, State = pcall(function(): any
			return self:Fold(self:Records():ReadVersion(Resolved, Version))
		end)
		if not Ok then
			return nil, Failed(`read version '{Version}' of`, Resolved, State)
		end
		return State, nil
	end)
end

function DataStore.Inspect(self: DataStore, Key: KeyLike): Future<Record?, Reason?>
	local Resolved = self:Resolve(Key, "Inspect")

	return Future.New(function(): (Record?, Reason?)
		local Ok, Stored = pcall(function(): Record
			return self:ReadRecord(Resolved)
		end)
		if not Ok then
			return nil, Failed("inspect", Resolved, Stored)
		end
		return TableUtil.DeepFreeze(TableUtil.DeepCopy(Stored)), nil
	end)
end

function DataStore.Edit(self: DataStore, Key: KeyLike, Kind: string, Fields: { [any]: any }?): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Edit")

	local Op = MakeOp.New(Kind, Fields)

	local Named, Unnamed = MakeOp.Stamp(Op)
	if not Named then
		warn(`Ledger: Edit rejected op '{Kind}', {Unnamed}`)
		return Rejected(INVALID)
	end

	local Storable, Unstorable = IsStorable.Op(Op)
	if not Storable then
		warn(`Ledger: Edit rejected op '{Kind}', {Unstorable}`)
		return Rejected(INVALID)
	end

	return Future.New(function(): (boolean, Reason?)
		return self:Written(Resolved, Op, `edit '{Kind}'`)
	end)
end

function DataStore.Transfer(self: DataStore, From: KeyLike, To: KeyLike, Amount: number, Id: string?): Future<boolean, Reason?>
	self:ExpectBalance("Transfer")
	local FromKey = self:Resolve(From, "Transfer")
	local ToKey = self:Resolve(To, "Transfer")
	assert(FromKey ~= ToKey, `Transfer needs two different keys, both resolved to '{FromKey}'`)
	assert(
		type(Amount) == "number" and Amount > 0 and Amount < math.huge,
		`Transfer needs a positive finite Amount, got {tostring(Amount)}`
	)
	assert(
		Id == nil or (type(Id) == "string" and #Id > 0 and #Id <= MAX_TRANSFER_ID and utf8.len(Id) ~= nil),
		`Transfer Id must be a string of 1 to {MAX_TRANSFER_ID} characters when given`
	)

	return Future.New(function(): (boolean, Reason?)
		local Ok, Moved, Why, Escrowed = pcall(function(): (boolean, Reason?, boolean?)
			return Transfer.Drive(
				self:Records(),
				self:Format(),
				FromKey,
				ToKey,
				Amount,
				Id
			)
		end)
		if not Ok then
			warn(`Ledger: the transfer from '{FromKey}' broke inside Ledger: {Moved}`)
			return false, UNRESOLVED
		end

		if Why == BUSY or Escrowed then
			Registry.Sweep:Add(self, FromKey)
		end
		return Moved :: boolean, Why :: Reason?
	end)
end

function DataStore.Tx(self: DataStore, Id: string, Legs: { TxLeg }): Future<boolean, Reason?>
	self:Live("Tx")
	assert(
		type(Id) == "string" and #Id > 0 and #Id <= MAX_TX_ID and utf8.len(Id) ~= nil,
		`Tx needs an Id first, a stable name of 1 to {MAX_TX_ID} characters derived from the thing being settled, never from the clock`
	)
	assert(type(Legs) == "table", "Tx takes an array of legs after the Id")
	assert(#Legs >= 2 and #Legs <= Tx.MAX_LEGS, `Tx takes 2 to {Tx.MAX_LEGS} legs, got {#Legs}`)

	local Mapped: { Tx.Leg } = table.create(#Legs) :: { Tx.Leg }
	local Targets: { LegTarget } = table.create(#Legs) :: { LegTarget }
	local Touched: { [string]: boolean } = {}

	for Index, Leg in Legs do
		Mapped[Index], Targets[Index] = MapLeg(self, Index, Leg, Touched)

		local Storable, Unstorable = LegStorable(Leg)
		if not Storable then
			warn(`Ledger: Tx rejected leg {Index} '{Leg.Kind}', {Unstorable}`)
			return Rejected(INVALID)
		end
	end

	assert(#Mapped == #Legs and #Targets == #Legs, "a transaction ended up with a different number of legs than it was given")

	return Future.New(function(): (boolean, Reason?)
		local Ok, Committed, Why = pcall(function(): (boolean, Reason?)
			return Tx.Drive(self.TxWrapper, Mapped, Id)
		end)
		if not Ok then
			warn(`Ledger: transaction '{Id}' broke inside Ledger and its legs might still be pending: {Committed}`)
			return false, UNRESOLVED
		end

		if Why == BUSY then
			for _, Target in Targets do
				Registry.Sweep:Add(Target.Store, Target.Key)
			end
		end
		return Committed :: boolean, Why :: Reason?
	end)
end

function DataStore.Resettle(self: DataStore, Key: KeyLike): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Resettle")

	return Future.New(function(): (boolean, Reason?)
		local Ok, Clean = pcall(function(): boolean
			return (self:Repair(Resolved))
		end)
		if not Ok then
			return false, Failed("finish what is unsettled on", Resolved, Clean)
		end
		return Clean, if Clean then nil else BUSY
	end)
end

function DataStore.RecoverTransfers(self: DataStore, Key: KeyLike): Future<boolean, Reason?>
	self:ExpectBalance("RecoverTransfers")
	local Resolved = self:Resolve(Key, "RecoverTransfers")

	return Future.New(function(): (boolean, Reason?)
		local Ok, Clean = pcall(function(): boolean
			local Held = self:Fold(self:ReadRecord(Resolved))._Held
			return (Transfer.Recover(self:Records(), self:Format(), Resolved, Held))
		end)
		if not Ok then
			return false, Failed("recover the transfers set aside on", Resolved, Clean)
		end
		return Clean, if Clean then nil else BUSY
	end)
end

function DataStore.ClearDelivered(self: DataStore, Key: KeyLike): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "ClearDelivered")

	return Future.New(function(): (boolean, Reason?)
		local Ok, Why = pcall(function()
			Transfer.Prune(self:Records(), Resolved)
		end)
		if not Ok then
			return false, Failed("clear the delivered transfers on", Resolved, Why)
		end
		return true, nil
	end)
end

function DataStore.Reset(self: DataStore, Key: KeyLike): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Reset")

	local Steps = self.Migrations
	local Known = #Steps
	local Op = MakeOp.New(RESET_KIND, { State = self.Initial, Version = Known, Floor = Log.FloorOf(Steps) })

	return Future.New(function(): (boolean, Reason?)
		return self:Written(Resolved, Op, "reset", function(Record: Record): boolean
			return (Record.Version or 0) <= Known
		end, BEHIND)
	end)
end

function DataStore.Erase(self: DataStore, Key: KeyLike): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Erase")

	if self.Keys == "Player" and Players:GetPlayerByUserId(Key :: any) ~= nil then
		warn(`Ledger: erasing {Resolved} while they are still in this server, so their session writes part of the record back`)
	end

	return Future.New(function(): (boolean, Reason?)
		local Holds, Amount = 0, 0
		if self.Options.Balance then
			Holds, Amount = HandOver(self, Resolved)
		end

		local Steps = self.Migrations
		local Ok, Replaced = pcall(function(): Record
			return self:Records():Entomb(Resolved, Clock.Now(), function(Record: Record): Record
				local Fine, State = pcall(function(): any
					return self:Fold(Record)
				end)

				local Names = if Fine and type(State) == "table" then (State :: any)._Received else nil
				if type(Names) ~= "table" or next(Names) == nil then
					return { Ops = {}, Seen = {} }
				end

				local Fresh: any = TableUtil.DeepCopy(self.Initial)
				Fresh._Received = TableUtil.DeepCopy(Names)
				return {
					Ops = {},
					Seen = {},
					Snapshot = Fresh,
					Version = #Steps,
					Floor = Log.FloorOf(Steps)
				}
			end)
		end)

		if not Ok then
			return false, Failed("erase", Resolved, Replaced)
		end

		if Holds > 0 then
			warn(`Ledger: erased '{Resolved}' while {Holds} transfer(s) worth {Amount} had not finished, so that money is gone for good. check the audit log and pay the receivers back by hand`)
		end

		local Before = Replaced :: Record
		if Before.Erased ~= nil and not Transfer.Entombed(Before) then
			local Reached, Gone, Cause = pcall(function(): (boolean, any)
				return self.Wrapper:RemoveAsync(Resolved)
			end)
			if not (Reached and Gone) then
				Failed("take the old record off the datastore for", Resolved, if Reached then Cause else Gone)
			end
			return true, nil
		end

		self:Buried(Resolved, Before)
		return true, nil
	end)
end

function DataStore.Destroy(self: DataStore)
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
	Registry.Sweep:Forget(self)

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

table.freeze(DataStore)

local function New<D>(Config: Config<D>): Store<D>
	assert(
		not Registry.Claimed[Config.Name] and not Registry.Claimed[`{Config.Name}_Tx`],
		`a store named '{Config.Name}' already exists in this server`
	)
	Registry.Claimed[Config.Name] = true
	Registry.Claimed[`{Config.Name}_Tx`] = true

	if DataStoreWrapper.Swapped() then
		warn(`Ledger: store '{Config.Name}' is on a fake datastore, nothing it saves outlives this server. Ledger.UseReal() puts it back`)
	end

	local Base = Config.Reducer
	if Config.Balance then
		Base = Transfer.Wrap(Base, Config.Balance)
	end
	Base = Tx.Wrap(Base)

	local Initial = MakeInitial(Config.Default)
	local Steps: { Migration } = Config.Migrations or {}
	local Body = {
		Options = Config,
		Reducer = WrapSystem(Base, Initial, Steps),
		Wrapper = DataStoreWrapper.New(Config.Name),
		TxWrapper = DataStoreWrapper.New(`{Config.Name}_Tx`),
		Initial = Initial,
		Migrations = Steps,
		Keys = Config.Keys or "Player",
		Loaded = {},
		Waiters = {},
		Loads = {},
		Saving = {},
		Meter = { Skipped = 0, At = 0, Records = 0, Markers = 0, Swollen = 0, Said = 0 },
		Closed = false
	}
	local Built: DataStore = setmetatable(Body :: any, DataStore) :: any

	table.insert(Registry.Stores, Built)
	return Built :: any
end

return table.freeze({
	New = New
})
