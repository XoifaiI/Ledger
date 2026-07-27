--!strict
--!optimize 2

-- player data as a ledger not a document. state is a pure fold of an append only op log and there are no session locks

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Future = require("@self/Util/Future")
local SetInterval = require("@self/Util/SetInterval")
local TableUtil = require("@self/Util/TableUtil")
local Threads = require("@self/Util/Threads")
local DataStoreWrapper = require("@self/Util/DataStoreWrapper")
local Log = require("@self/Log")
local MakeOp = require("@self/MakeOp")
local Measure = require("@self/Measure")
local Reconcile = require("@self/Reconcile")
local IsStorable = require("@self/Storable")
local Session = require("@self/Session")
local Transfer = require("@self/Transfer")
local Tx = require("@self/Tx")
local Types = require("@self/Types")

type Future<T...> = Future.Future<T...>

export type Store<D> = Types.Store<D>
export type Session<S> = Types.Session<S>
export type Op = Types.Op
export type Reducer<S> = Types.Reducer<S>
export type KeyLike = Types.KeyLike
export type KeysMode = Types.KeysMode
export type Reason = Types.Reason
export type TxLeg = Types.TxLeg
export type Migration = Types.Migration

type Config = Types.Config
type Record = Types.Record<any>
type LoadedEntry = Types.LoadedEntry
type DataStoreImpl = Types.DataStoreImpl
type DataStore = Types.DataStore

type NewOptions<D> = {
	Name: string,
	Reducer: Types.Reducer<D>,
	Default: D,
	Balance: string?,
	Migrations: { Types.Migration }?,
	Keys: Types.KeysMode?
}

type Allow = (Record) -> boolean
type Stranded = { Store: DataStore, Key: string, Tries: number }
type LegTarget = { Store: DataStore, Key: string }

local AUTOSAVE_INTERVAL = 30
local MIN_WRITE_BUDGET = 4
local SHUTDOWN_ATTEMPTS = 2

local COMPACT_THRESHOLD = 128
local COMPACT_BYTES = 1024 * 1024
local COMPACT_SAMPLE = 16

local MAX_KEY = 50
local MAX_NAME = 47
local MAX_TRANSFER_ID = 64
local MAX_TX_ID = 50

local SWEEP_INTERVAL = 60
local SWEEP_LIMIT = 256
local SWEEP_TRIES = 5
local MIN_SWEEP_BUDGET = 8

local RESET_KIND = "__Reset"

local Registry = {
	Stores = {} :: { DataStore },
	Claimed = {} :: { [string]: boolean }
}

local Ledger = {}

local REFUSED: Reason = "Refused"
local INVALID: Reason = "Invalid"
local UNRESOLVED: Reason = "Unresolved"
local BUSY: Reason = "Busy"

local function ShouldCompact(Ops: number, Bytes: number): boolean
	return Ops >= COMPACT_THRESHOLD or Bytes >= COMPACT_BYTES
end

local function MakeInitial(Default: any): any
	return TableUtil.DeepFreeze(TableUtil.DeepCopy(Default))
end

local function ValidId(UserId: any): boolean
	return type(UserId) == "number" and UserId == UserId // 1 and UserId > 0 and UserId < math.huge
end

local function Affordable(): boolean
	return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync) >= MIN_SWEEP_BUDGET
		and DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync) >= MIN_SWEEP_BUDGET
end

local function Rejected(Why: Reason?): Future<boolean, Reason?>
	return Future.Completed(false, Why)
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

		local Next = Reconcile(Initial, TableUtil.DeepCopy(Snapshot))
		Next._Received = State._Received
		Next._Held = State._Held
		return Next
	end

	return Combined
end

local function MigrationDrops(Options: Config): { string }
	local Steps = Options.Migrations
	if Steps == nil or #Steps == 0 then
		return {}
	end

	local Ran, Migrated = pcall(function(): any
		local State: any = TableUtil.DeepCopy(Options.Default)
		for _, Step in Steps :: { Migration } do
			State = if type(Step) == "function" then Step(State) else Step.Apply(State)
			if type(State) ~= "table" then
				return nil
			end
		end
		return State
	end)
	if not Ran or type(Migrated) ~= "table" then
		return {}
	end

	local Dropped: { string } = {}
	for Key in Options.Default do
		if Migrated[Key] == nil then
			table.insert(Dropped, tostring(Key))
		end
	end
	return Dropped
end

local function Vet(Options: Config)
	assert(type(Options) == "table", "New takes an options table")
	assert(
		type(Options.Name) == "string" and #Options.Name > 0 and #Options.Name <= MAX_NAME,
		`New needs Name, a datastore name of 1 to {MAX_NAME} characters (the transaction store appends _Tx)`
	)
	assert(type(Options.Reducer) == "function", "New needs Reducer, a (State, Op) -> State? function")
	assert(type(Options.Default) == "table", "New needs Default, the fresh state table")
	assert(
		Options.Keys == nil or Options.Keys == "Player" or Options.Keys == "String",
		`Keys must be "Player" or "String"`
	)

	for Key in Options.Default do
		assert(
			not (type(Key) == "string" and string.sub(Key, 1, 1) == "_"),
			`Default key '{tostring(Key)}' uses the _ prefix reserved for Ledger's bookkeeping`
		)
	end
	local Storable, Unstorable = IsStorable.Value(Options.Default)
	assert(Storable, `Default cannot be stored: {Unstorable}`)

	if Options.Migrations ~= nil then
		assert(type(Options.Migrations) == "table", "Migrations must be an array of steps")
		for Index, Step in Options.Migrations do
			assert(
				type(Step) == "function" or (type(Step) == "table" and type((Step :: any).Apply) == "function"),
				`migration {Index} must be a function or a table with an Apply function`
			)
		end
	end

	if Options.Balance ~= nil then
		assert(type(Options.Balance) == "string" and #Options.Balance > 0, "Balance must name a field, like \"Gold\"")
		assert(
			type(Options.Default[Options.Balance]) == "number",
			`Balance names '{Options.Balance}' but the Default has no numeric field by that name`
		)
	end

	for _, Dropped in MigrationDrops(Options) do
		warn(`Ledger: a migration on '{Options.Name}' removes '{Dropped}' but Default still declares it, so Reconcile fills it back in on every load and the removal never takes. drop it from Default too`)
	end
end

local Sweeper = {}
Sweeper.__index = Sweeper

export type Sweeper = setmetatable<{
	Entries: { [string]: Stranded },
	Count: number,
	Ticker: thread
}, typeof(Sweeper)>

function Sweeper.New(): Sweeper
	local self = setmetatable({ Entries = {}, Count = 0, Ticker = nil :: any }, Sweeper)
	self.Ticker = SetInterval(SWEEP_INTERVAL, function()
		self:Pass()
	end)
	return self
end

function Sweeper.Add(self: Sweeper, Store: DataStore, Key: string)
	local Mark = Store:Mark(Key)
	if self.Entries[Mark] ~= nil or self.Count >= SWEEP_LIMIT then
		return
	end
	self.Entries[Mark] = { Store = Store, Key = Key, Tries = 0 }
	self.Count += 1
end

function Sweeper.Drop(self: Sweeper, Mark: string)
	if self.Entries[Mark] == nil then
		return
	end
	self.Entries[Mark] = nil
	self.Count -= 1
end

function Sweeper.Pass(self: Sweeper)
	for Mark, Entry in self.Entries do
		if not Affordable() then
			return
		end

		Entry.Tries += 1
		local Ok, Clean = pcall(function(): boolean
			return Entry.Store:Resettle(Entry.Key)
		end)
		if (Ok and Clean) or Entry.Tries >= SWEEP_TRIES then
			self:Drop(Mark)
		end
	end
end

function Sweeper.Stop(self: Sweeper)
	task.cancel(self.Ticker)
	table.clear(self.Entries)
	self.Count = 0
end

Registry.Sweep = Sweeper.New()

local DataStore = {} :: DataStoreImpl
DataStore.__index = DataStore

function DataStore.Mark(self: DataStore, Key: string): string
	return `{self.Wrapper.Name}\0{Key}`
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

function DataStore.Resolve(self: DataStore, Key: KeyLike, What: string): string
	local Resolved = self:KeyFor(Key)
	assert(Resolved, `{What} needs {self:KeyIssue()}, got {typeof(Key)}`)
	return Resolved
end

function DataStore.ExpectPlayers(self: DataStore, What: string)
	assert(self.Keys == "Player", `{What} is for player stores, '{self.Options.Name}' uses string keys`)
end

function DataStore.ExpectBalance(self: DataStore, What: string)
	assert(self.Options.Balance, `{What} needs the store to name a Balance field, like Balance = "Gold"`)
end

function DataStore.Fold(self: DataStore, Record: Record): any
	return Log.Shape(self.Reducer, self.Initial, self.Migrations):Fold(Record)
end

function DataStore.ReadRecord(self: DataStore, Key: string): Record
	return Log.New(self.Wrapper):Read(Key)
end

function DataStore.Watch(self: DataStore, Key: string, Record: Record)
	if Log.HasPending(Record) then
		Registry.Sweep:Add(self, Key)
	end
end

function DataStore.Resettle(self: DataStore, Key: string): boolean
	local Record = Tx.Settle(Log.New(self.Wrapper), self.TxWrapper, Key, self:ReadRecord(Key))
	if Log.HasPending(Record) then
		return false
	end

	local Held = self:Fold(Record)._Held
	if type(Held) ~= "table" or next(Held) == nil then
		return true
	end

	Transfer.Recover(Log.New(self.Wrapper), Log.Shape(self.Reducer, self.Initial, self.Migrations), Key, Held)
	return true
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
		return Log.New(self.Wrapper):Append(Key, { Op })
	end
	return Log.New(self.Wrapper):Append(Key, { Op }, Guard)
end

function DataStore.Maintain(self: DataStore, Key: string, Record: Record): Record
	local Settled = Record
	if Log.HasPending(Record) then
		local Ok, Resolution = pcall(function(): Record
			return Tx.Settle(Log.New(self.Wrapper), self.TxWrapper, Key, Record)
		end)
		if Ok then
			Settled = Resolution
		else
			warn(`Ledger: could not settle a pending transaction leg on '{Key}' during a write, it stays pending: {Resolution}`)
		end
	end

	self:Watch(Key, Settled)

	local Bytes = if #Settled.Ops >= COMPACT_SAMPLE then Measure(Settled.Ops) else 0
	if not ShouldCompact(#Settled.Ops, Bytes) then
		return Settled
	end

	local Packed, Reason = pcall(function()
		Log.New(self.Wrapper):Compact(Key, Log.Shape(self.Reducer, self.Initial, self.Migrations))
	end)
	if not Packed then
		warn(`Ledger: could not compact '{Key}', the write still landed and the log stays long: {Reason}`)
	end
	return Settled
end

function DataStore.Written(self: DataStore, Key: string, Op: Op, What: string, Guard: Allow?): (boolean, Reason?)
	local Ok, Took = pcall(function(): boolean
		local Record = self:Append(Key, Op, Guard)
		if Guard ~= nil and not Guard(Record) then
			return false
		end
		Record = self:Maintain(Key, Record)
		return Log.Shape(self.Reducer, self.Initial, self.Migrations):Accepted(Record, Op.Id)
	end)

	if not Ok then
		warn(`Ledger: {What} on '{Key}' could not be written, it may still have landed: {Took}`)
		return false, UNRESOLVED
	end
	return Took, if Took then nil else REFUSED
end

function DataStore.Autosave(self: DataStore, UserId: number)
	local Entry = self.Loaded[UserId]
	if Entry == nil then
		return
	end

	local Writing = #Entry.Active.Pending > 0
	local Pool = if Writing then Enum.DataStoreRequestType.UpdateAsync else Enum.DataStoreRequestType.GetAsync
	if DataStoreService:GetRequestBudgetForRequestType(Pool) < MIN_WRITE_BUDGET then
		warn(`Ledger: autosave for {UserId} is skipping, this server is out of datastore budget and ops are piling up unsaved`)
		return
	end

	local Ok = Entry.Active:Flush():Wait()
	if Ok and ShouldCompact(Entry.Active.LogSize, Entry.Active.LogBytes) then
		Ok = Entry.Active:Compact():Wait()
	end
	if Ok then
		return
	end
	warn(`Ledger: autosave for {UserId} is failing, the datastore is likely down`)
end

function DataStore.Save(self: DataStore, Active: Session<any>): Future<boolean>
	local Job = Active:Release()
	self.Saving[Job] = true
	return Job
end

function DataStore.Load(self: DataStore, Player: Player)
	self:ExpectPlayers("Load")
	local UserId = Player.UserId

	if self.Loaded[UserId] ~= nil then
		warn(`Ledger: {Player.Name} already has a live session, ignoring the second Load`)
		return
	end
	if self.Loading[UserId] and not self.Leaving[UserId] then
		warn(`Ledger: {Player.Name} is already loading, ignoring the second Load`)
		return
	end
	self.Leaving[UserId] = nil
	self.Loading[UserId] = true

	local Job = Session.Load(Log.New(self.Wrapper), Log.Shape(self.Reducer, self.Initial, self.Migrations), tostring(UserId), self.TxWrapper)
	local Active = Job:Wait()

	self.Loading[UserId] = nil
	local WasLeaving = self.Leaving[UserId] == true
	self.Leaving[UserId] = nil

	if not Job:Happened() or Active == nil then
		Player:Kick("Your data failed to load, please rejoin")
		self:Wake(UserId, nil)
		return
	end

	if self.Loaded[UserId] ~= nil then
		warn(`Ledger: {Player.Name} was loaded twice concurrently, releasing the duplicate session`)
		Active:Release()
		return
	end

	if WasLeaving or not Player.Parent then
		Active:Release()
		self:Wake(UserId, nil)
		return
	end

	self.Loaded[UserId] = {
		Active = Active,
		Ticker = SetInterval(AUTOSAVE_INTERVAL, function()
			self:Autosave(UserId)
		end)
	}
	self:Wake(UserId, Active)

	local Held = Active:Get()._Held
	if type(Held) == "table" and next(Held) ~= nil then
		task.spawn(Transfer.Recover, self.Wrapper, self.Reducer, self.Initial, self.Migrations, UserId, Held)
	end
end

function DataStore.Unload(self: DataStore, Player: Player)
	self:ExpectPlayers("Unload")
	local UserId = Player.UserId
	local Entry = self.Loaded[UserId]

	if Entry == nil then
		if self.Loading[UserId] then
			self.Leaving[UserId] = true
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

function DataStore.Peek(self: DataStore, Key: KeyLike): Future<any>
	local Resolved = self:Resolve(Key, "Peek")

	return Future.New(function(): any
		local Record = self:ReadRecord(Resolved)
		self:Watch(Resolved, Record)
		return self:Fold(Record)
	end)
end

function DataStore.History(self: DataStore, Key: KeyLike, Limit: number?): Future<{ Types.HistoryEntry }>
	local Resolved = self:Resolve(Key, "History")
	local Page = math.clamp(if type(Limit) == "number" then Limit else 25, 1, 100)

	return Future.New(function(): { Types.HistoryEntry }
		local Ok, Pages = self.Wrapper:ListVersionsAsync(Resolved, Enum.SortDirection.Descending, nil, nil, Page)
		if not Ok then
			error(Pages)
		end

		local Rows: { Types.HistoryEntry } = {}
		for _, Info in (Pages :: DataStoreVersionPages):GetCurrentPage() do
			local Version = Info :: DataStoreObjectVersionInfo
			table.insert(Rows, { Version = Version.Version, At = Version.CreatedTime / 1000, Deleted = Version.IsDeleted })
		end
		return Rows
	end)
end

function DataStore.PeekVersion(self: DataStore, Key: KeyLike, Version: string): Future<any>
	local Resolved = self:Resolve(Key, "PeekVersion")
	assert(type(Version) == "string" and #Version > 0, "PeekVersion needs a Version string from History")

	return Future.New(function(): any
		return self:Fold(Log.New(self.Wrapper):ReadVersion(Resolved, Version))
	end)
end

function DataStore.Edit(self: DataStore, Key: KeyLike, Kind: string, Fields: { [any]: any }?): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Edit")

	local Op = MakeOp(Kind, Fields)
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
				Log.New(self.Wrapper),
				Log.Shape(self.Reducer, self.Initial, self.Migrations),
				FromKey,
				ToKey,
				Amount,
				Id
			)
		end)
		if not Ok then
			warn(`Ledger: transfer from '{FromKey}' failed inside Ledger: {Moved}`)
			return false, UNRESOLVED
		end

		if Why == BUSY or Escrowed then
			Registry.Sweep:Add(self, FromKey)
		end
		return Moved :: boolean, Why :: Reason?
	end)
end

function DataStore.Tx(self: DataStore, Id: string, Legs: { TxLeg }): Future<boolean, Reason?>
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
		assert(type(Leg) == "table", `Tx leg {Index} is not a table`)

		local Target: DataStore = self
		if Leg.Store ~= nil then
			assert(
				getmetatable(Leg.Store :: any) == DataStore,
				`Tx leg {Index} names a Store that was not built by Ledger.New`
			)
			Target = Leg.Store :: any
		end

		local Raw = if Target.Keys == "Player" then Leg.UserId else Leg.Key
		local Resolved = Target:KeyFor(Raw)
		assert(Resolved, `Tx leg {Index} needs {Target:KeyIssue()}`)
		assert(type(Leg.Kind) == "string" and #Leg.Kind > 0, `Tx leg {Index} needs a non-empty string Kind`)
		assert(Leg.Fields == nil or type(Leg.Fields) == "table", `Tx leg {Index} Fields must be a table when given`)

		local Probe: { [any]: any } = if Leg.Fields then table.clone(Leg.Fields) else {}
		Probe.Id = "probe"
		Probe.Kind = Leg.Kind
		local Storable, Unstorable = IsStorable.Op(Probe)
		assert(Storable, `Tx leg {Index} cannot be stored: {Unstorable}`)

		local Mark = Target:Mark(Resolved)
		assert(not Touched[Mark], `Tx leg {Index} touches '{Resolved}' twice, a transaction may only touch a key once per store`)
		Touched[Mark] = true

		Mapped[Index] = {
			Key = Resolved,
			Kind = Leg.Kind,
			Fields = Leg.Fields,
			Log = Log.New(Target.Wrapper),
			Shape = Log.Shape(Target.Reducer, Target.Initial, Target.Migrations),
			TxStore = Target.TxWrapper
		}
		Targets[Index] = { Store = Target, Key = Resolved }
	end

	return Future.New(function(): (boolean, Reason?)
		local Ok, Committed, Why = pcall(function(): (boolean, Reason?)
			return Tx.Drive(self.TxWrapper, Mapped, Id)
		end)
		if not Ok then
			warn(`Ledger: transaction '{Id}' failed inside Ledger and its legs may still be pending: {Committed}`)
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

function DataStore.RecoverTransfers(self: DataStore, Key: KeyLike): Future<()>
	self:ExpectBalance("RecoverTransfers")
	local Resolved = self:Resolve(Key, "RecoverTransfers")

	return Future.New(function()
		local Held = self:Fold(self:ReadRecord(Resolved))._Held
		Transfer.Recover(Log.New(self.Wrapper), Log.Shape(self.Reducer, self.Initial, self.Migrations), Resolved, Held)
	end)
end

function DataStore.ClearDelivered(self: DataStore, Key: KeyLike): Future<()>
	local Resolved = self:Resolve(Key, "ClearDelivered")

	return Future.New(function()
		Transfer.Prune(Log.New(self.Wrapper), Resolved)
	end)
end

function DataStore.Reset(self: DataStore, Key: KeyLike): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Reset")

	local Steps = self.Migrations
	local Known = #Steps
	local Op = MakeOp(RESET_KIND, { State = self.Options.Default, Version = Known, Floor = Log.FloorOf(Steps) })

	return Future.New(function(): (boolean, Reason?)
		return self:Written(Resolved, Op, "reset", function(Record: Record): boolean
			return (Record.Version or 0) <= Known
		end)
	end)
end

function DataStore.Erase(self: DataStore, Key: KeyLike): Future<()>
	local Resolved = self:Resolve(Key, "Erase")

	if self.Keys == "Player" and Players:GetPlayerByUserId(Key :: any) ~= nil then
		warn(`Ledger: erasing {Resolved} while they are still in this server, so their session will write part of the record back`)
	end

	return Future.New(function()
		local Holds, Amount = 0, 0
		if self.Options.Balance then
			local Read, Held = pcall(function(): any
				return self:Fold(self:ReadRecord(Resolved))._Held
			end)

			if not Read then
				warn(`Ledger: could not check '{Resolved}' for unfinished transfers before erasing it, so any money still in flight is gone for good: {Held}`)
			elseif type(Held) == "table" and next(Held) ~= nil then
				pcall(function()
					Transfer.Recover(
						Log.New(self.Wrapper),
						Log.Shape(self.Reducer, self.Initial, self.Migrations),
						Resolved,
						Held
					)
				end)

				local Again, Left = pcall(function(): any
					return self:Fold(self:ReadRecord(Resolved))._Held
				end)
				if not Again then
					warn(`Ledger: could not re-check '{Resolved}' after finishing its transfers, so any that were still in flight are gone for good: {Left}`)
				elseif type(Left) == "table" then
					for _, Entry in Left do
						if type(Entry) == "table" and type(Entry.Amount) == "number" then
							Holds += 1
							Amount += Entry.Amount
						end
					end
				end
			end
		end

		local Ok, Reason = self.Wrapper:RemoveAsync(Resolved)
		if not Ok then
			error(Reason)
		end

		if Holds > 0 then
			warn(`Ledger: erased '{Resolved}' while {Holds} transfer(s) worth {Amount} were still in flight, so that money is gone for good. check the audit log and pay the receivers back by hand`)
		end
	end)
end

table.freeze(DataStore)

function Ledger.New<D>(Options: NewOptions<D>): Store<D>
	local Config = Options :: any
	Vet(Config)
	assert(
		not Registry.Claimed[Config.Name] and not Registry.Claimed[`{Config.Name}_Tx`],
		`a store named '{Config.Name}' already exists in this server`
	)
	Registry.Claimed[Config.Name] = true
	Registry.Claimed[`{Config.Name}_Tx`] = true

	local Base = Config.Reducer
	if Config.Balance then
		Base = Transfer.Wrap(Base, Config.Balance)
	end
	Base = Tx.Wrap(Base)

	local Initial = MakeInitial(Config.Default)
	local Steps: { Types.Migration } = Config.Migrations or {}
	local Built: DataStore = setmetatable({
		Options = Config,
		Reducer = WrapSystem(Base, Initial, Steps),
		Wrapper = DataStoreWrapper.New(Config.Name),
		TxWrapper = DataStoreWrapper.New(`{Config.Name}_Tx`),
		Initial = Initial,
		Migrations = Steps,
		Keys = Config.Keys or "Player",
		Loaded = {},
		Waiters = {},
		Leaving = {},
		Loading = {},
		Saving = {}
	}, DataStore)

	table.insert(Registry.Stores, Built)
	return Built :: any
end

function Ledger.Sweep()
	Registry.Sweep:Pass()
end

function Ledger.CloseAll()
	Registry.Sweep:Stop()

	for _, Store in Registry.Stores do
		Store.Wrapper:SkipAllQueuesToLastEnqueued()
		Store.Wrapper.Attempts = SHUTDOWN_ATTEMPTS
		Store.TxWrapper:SkipAllQueuesToLastEnqueued()
		Store.TxWrapper.Attempts = SHUTDOWN_ATTEMPTS
	end
	Tx.ShutdownHomes(SHUTDOWN_ATTEMPTS)

	for _, Store in Registry.Stores do
		for UserId, Entry in Store.Loaded do
			Store.Loaded[UserId] = nil
			task.cancel(Entry.Ticker)
			Store:Save(Entry.Active)
		end
	end

	for _, Store in Registry.Stores do
		local Jobs: { Future<boolean> } = {}
		for Job in Store.Saving do
			table.insert(Jobs, Job)
		end
		for _, Job in Jobs do
			Job:Wait()
			Store.Saving[Job] = nil
		end
	end
end

return table.freeze(Ledger)
