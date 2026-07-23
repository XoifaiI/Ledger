--!strict
--!optimize 2

--[=[
    Ledger: player data as a ledger, not a document. state is a pure fold of an append
    only op log, every change is a validated intent, and there are no session locks
    anywhere. New builds an independent store per datastore name, keyed by player ids
    (the default, with the session lifecycle) or by plain string keys (entity stores:
    clans, listings, anything shared, which get the cross-server surface only).

    the boot owns the lifecycle for a player store: Load on join, Unload on leave, and
    Ledger.CloseAll on shutdown, which flushes every store.

    Return type: frozen factory table, stores are typed by an annotated binding
    Example usage:
        local Ledger = require(ServerStorage.Ledger)
        local Store: Ledger.Store<Profile> = Ledger.New({
            Name = "PlayerData", Reducer = Reducer, Default = Default, Balance = "Gold",
        })
        Store:Load(Player)
        local Session = Store:Expect(Player)
--]=]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Future = require("@self/Util/Future")
local SetInterval = require("@self/Util/SetInterval")
local TableUtil = require("@self/Util/TableUtil")
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

type Op = Types.Op
type Future<T...> = Future.Future<T...>

export type Store<D> = Types.Store<D>
export type Session<S> = Types.Session<S>
export type KeyLike = Types.KeyLike
export type KeysMode = Types.KeysMode
export type TxLeg = Types.TxLeg
export type Migration = Types.Migration

type Config = Types.Config
type Runtime = Types.Runtime
type DataStoreImpl = Types.DataStoreImpl
type DataStore = Types.DataStore

type NewOptions<D> = {
	Name: string,
	Reducer: Types.Reducer<D>,
	Default: D,
	Balance: string?,
	Migrations: { Types.Migration }?,
	Keys: Types.KeysMode?,
}

local AUTOSAVE_INTERVAL = 30
local COMPACT_THRESHOLD = 128
local COMPACT_BYTES = 1024 * 1024
local RELEASE_ATTEMPTS = 3
local SHUTDOWN_ATTEMPTS = 2
local MAX_KEY = 50

local RESET_KIND = "__Reset"

local Claimed: { [string]: boolean } = {}
local Instances: { DataStore } = {}
local InFlight: { [Future<()>]: boolean } = {}

local function MakeInitial(Default: any): any
	return TableUtil.DeepFreeze(TableUtil.DeepCopy(Default))
end

local function WrapSystem(GameReducer: Types.Reducer<any>, Initial: any): Types.Reducer<any>
	local function Combined(State: any, Op: Op): any?
		if Op.Kind ~= RESET_KIND then
			return GameReducer(State, Op)
		end

		local Snapshot = Op.State
		if type(Snapshot) ~= "table" then
			return nil
		end

		local Next = Reconcile(Initial, TableUtil.DeepCopy(Snapshot))
		Next._Received = State._Received
		Next._Held = State._Held
		return Next
	end

	return Combined
end

local function Wake(Live: Runtime, UserId: number, Active: Session<any>?)
	local List = Live.Waiters[UserId]
	if not List then
		return
	end
	Live.Waiters[UserId] = nil
	for _, Thread in List do
		task.spawn(Thread, Active)
	end
end

local function Save(Active: Session<any>, UserId: number): Future<()>
	local Job = Future.New(function()
		for _ = 1, RELEASE_ATTEMPTS do
			if Active:Release():Happened(true) then
				return
			end
		end
		warn(`Ledger: final save for {UserId} failed after {RELEASE_ATTEMPTS} attempts, the datastore is likely down and recent unsaved progress may be lost`)
	end)
	InFlight[Job] = true
	return Job
end

local DataStore = {} :: DataStoreImpl
DataStore.__index = DataStore

local function ValidId(UserId: any): boolean
	return type(UserId) == "number" and UserId == UserId // 1 and UserId > 0 and UserId < math.huge
end

local function KeyFor(self: DataStore, Value: any): string?
	if self.Live.Keys == "Player" then
		return if ValidId(Value) then tostring(Value) else nil
	end
	return if type(Value) == "string" and #Value > 0 and #Value <= MAX_KEY and utf8.len(Value) ~= nil
		then Value
		else nil
end

local function KeyIssue(self: DataStore): string
	return if self.Live.Keys == "Player"
		then "a positive integer UserId"
		else `a key string of 1 to {MAX_KEY} characters`
end

local function ExpectPlayers(self: DataStore, What: string)
	assert(self.Live.Keys == "Player", `{What} is for player stores, '{self.Live.Options.Name}' uses string keys`)
end

local function Vet(Options: Config)
	assert(type(Options) == "table", "New takes an options table")
	assert(
		type(Options.Name) == "string" and #Options.Name > 0 and #Options.Name <= 47,
		"New needs Name, a datastore name of 1 to 47 characters (the transaction store appends _Tx)"
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
end

function DataStore.Load(self: DataStore, Player: Player)
	ExpectPlayers(self, "Load")
	local Live = self.Live
	local UserId = Player.UserId

	if Live.Loaded[UserId] then
		warn(`Ledger: {Player.Name} already has a live session, ignoring the second Load`)
		return
	end
	Live.Leaving[UserId] = nil

	local Job = Session.Load(Live.Wrapper, tostring(UserId), Live.Reducer, Live.Initial, Live.Migrations, Live.TxWrapper)
	local Active = Job:Wait()

	if not Job:Happened() or not Active then
		Player:Kick("Your data failed to load, please rejoin")
		Wake(Live, UserId, nil)
		return
	end

	if Live.Loaded[UserId] then
		warn(`Ledger: {Player.Name} was loaded twice concurrently, releasing the duplicate session`)
		Active:Release()
		return
	end

	if Live.Leaving[UserId] or not Player.Parent then
		Live.Leaving[UserId] = nil
		Active:Release()
		Wake(Live, UserId, nil)
		return
	end

	local LastFailed = false
	local Ticker = SetInterval(AUTOSAVE_INTERVAL, function()
		local Entry = Live.Loaded[UserId]
		if not Entry then
			return
		end

		if DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync) < 1 then
			return
		end

		local Ok = Entry.Active:Flush():Happened(true)
		if Ok and (Entry.Active.LogSize >= COMPACT_THRESHOLD or Entry.Active.LogBytes >= COMPACT_BYTES) then
			Ok = Entry.Active:Compact():Happened(true)
		end

		if Ok == LastFailed then
			LastFailed = not Ok
			if not Ok then
				warn(`Ledger: autosave for {UserId} is failing, the datastore is likely down`)
			end
		end
	end)

	Live.Loaded[UserId] = { Active = Active, Ticker = Ticker }
	Wake(Live, UserId, Active)

	local Held = Active:Get()._Held
	if type(Held) == "table" and next(Held) then
		task.spawn(Transfer.Recover, Live.Wrapper, Live.Reducer, Live.Initial, Live.Migrations, UserId, Held)
	end
end

function DataStore.Unload(self: DataStore, Player: Player)
	ExpectPlayers(self, "Unload")
	local Live = self.Live
	local UserId = Player.UserId
	local Entry = Live.Loaded[UserId]
	if not Entry then
		Live.Leaving[UserId] = true
		Wake(Live, UserId, nil)
		return
	end

	Live.Loaded[UserId] = nil
	task.cancel(Entry.Ticker)

	local Job = Save(Entry.Active, UserId)
	Job:Wait()
	InFlight[Job] = nil
end

function DataStore.Get(self: DataStore, Player: Player): Session<any>?
	ExpectPlayers(self, "Get")
	local Entry = self.Live.Loaded[Player.UserId]
	return if Entry then Entry.Active else nil
end

function DataStore.Expect(self: DataStore, Player: Player): Session<any>
	ExpectPlayers(self, "Expect")
	local Entry = self.Live.Loaded[Player.UserId]
	return assert(Entry and Entry.Active, `data for {Player.Name} is not loaded`)
end

function DataStore.IsLoaded(self: DataStore, Player: Player): boolean
	ExpectPlayers(self, "IsLoaded")
	return self.Live.Loaded[Player.UserId] ~= nil
end

function DataStore.WaitForLoaded(self: DataStore, Player: Player): Session<any>?
	ExpectPlayers(self, "WaitForLoaded")
	local Live = self.Live
	local Entry = Live.Loaded[Player.UserId]
	if Entry then
		return Entry.Active
	end
	if not Player.Parent then
		return nil
	end

	local List = Live.Waiters[Player.UserId]
	if not List then
		List = {}
		Live.Waiters[Player.UserId] = List
	end
	table.insert(List, coroutine.running())
	return coroutine.yield()
end

function DataStore.Read(self: DataStore, Player: Player): any
	ExpectPlayers(self, "Read")
	local Entry = self.Live.Loaded[Player.UserId]
	return if Entry then Entry.Active:Get() else nil
end

function DataStore.Peek(self: DataStore, Key: KeyLike): Future<any>
	local Live = self.Live
	local Resolved = KeyFor(self, Key)
	if not Resolved then
		return Future.Errored(`Peek needs {KeyIssue(self)}, got {typeof(Key)}`)
	end

	return Future.New(function(): any
		local Record = Log.Read(Live.Wrapper, Resolved)
		return Log.FoldRecord(Record, Live.Initial, Live.Reducer, Live.Migrations)
	end)
end

function DataStore.History(self: DataStore, Key: KeyLike, Limit: number?): Future<{ Types.HistoryEntry }>
	local Live = self.Live
	local Resolved = KeyFor(self, Key)
	if not Resolved then
		return Future.Errored(`History needs {KeyIssue(self)}, got {typeof(Key)}`)
	end

	return Future.New(function(): { Types.HistoryEntry }
		local Ok, Pages = Live.Wrapper:ListVersionsAsync(
			Resolved,
			Enum.SortDirection.Descending,
			nil,
			nil,
			math.clamp(if type(Limit) == "number" then Limit else 25, 1, 100)
		)
		if not Ok then
			error(Pages)
		end

		local Rows: { Types.HistoryEntry } = {}
		for _, Info in (Pages :: DataStoreVersionPages):GetCurrentPage() do
			table.insert(Rows, {
				Version = (Info :: DataStoreObjectVersionInfo).Version,
				At = (Info :: DataStoreObjectVersionInfo).CreatedTime / 1000,
				Deleted = (Info :: DataStoreObjectVersionInfo).IsDeleted,
			})
		end
		return Rows
	end)
end

function DataStore.PeekVersion(self: DataStore, Key: KeyLike, Version: string): Future<any>
	local Live = self.Live
	local Resolved = KeyFor(self, Key)
	if not Resolved or type(Version) ~= "string" or #Version == 0 then
		return Future.Errored(`PeekVersion needs {KeyIssue(self)} and a Version string from History`)
	end

	return Future.New(function(): any
		local Record = Log.ReadVersion(Live.Wrapper, Resolved, Version)
		return Log.FoldRecord(Record, Live.Initial, Live.Reducer, Live.Migrations)
	end)
end

function DataStore.Edit(self: DataStore, Key: KeyLike, Kind: string, Fields: { [any]: any }?): Future<()>
	local Live = self.Live
	local Resolved = KeyFor(self, Key)
	if not Resolved then
		return Future.Errored(`Edit needs {KeyIssue(self)}, got {typeof(Key)}`)
	end

	local Op = MakeOp(Kind, Fields)
	local Storable, Reason = IsStorable.Op(Op)
	if not Storable then
		return Future.Errored(`Edit rejected op '{Kind}', {Reason}`)
	end

	return Future.New(function()
		local Record = Log.Append(Live.Wrapper, Resolved, { Op })
		if #Record.Ops >= COMPACT_THRESHOLD or (#Record.Ops > 0 and #Record.Ops % 16 == 0 and Measure(Record) >= COMPACT_BYTES) then
			Log.Compact(Live.Wrapper, Resolved, Live.Reducer, Live.Initial, Live.Migrations)
		end
	end)
end

function DataStore.Transfer(self: DataStore, From: KeyLike, To: KeyLike, Amount: number): Future<boolean>
	local Live = self.Live

	if not Live.Options.Balance then
		warn("Ledger: Transfer needs the store to name a Balance field, like Balance = \"Gold\"")
		return Future.Completed(false)
	end

	local FromKey = KeyFor(self, From)
	local ToKey = KeyFor(self, To)
	if not FromKey or not ToKey or FromKey == ToKey then
		warn(`Ledger: Transfer needs two different keys, each {KeyIssue(self)}`)
		return Future.Completed(false)
	end

	return Future.New(function(): boolean
		return Transfer.Drive(Live.Wrapper, Live.Reducer, Live.Initial, FromKey, ToKey, Amount, Live.Migrations)
	end)
end

function DataStore.Tx(self: DataStore, Legs: { Types.TxLeg }): Future<boolean>
	if type(Legs) ~= "table" then
		warn("Ledger: Tx takes an array of legs")
		return Future.Completed(false)
	end

	local Mapped: { Tx.Leg } = table.create(#Legs) :: { Tx.Leg }
	for Index, Leg in Legs do
		if type(Leg) ~= "table" then
			warn(`Ledger: rejected transaction, leg {Index} is not a table`)
			return Future.Completed(false)
		end

		local Target: DataStore = self
		if Leg.Store ~= nil then
			if getmetatable(Leg.Store :: any) ~= DataStore then
				warn(`Ledger: rejected transaction, leg {Index} Store is not a store built by Ledger.New`)
				return Future.Completed(false)
			end
			Target = Leg.Store :: any
		end

		local Raw = if Target.Live.Keys == "Player" then Leg.UserId else Leg.Key
		local Resolved = KeyFor(Target, Raw)
		if not Resolved or type(Leg.Kind) ~= "string" or #Leg.Kind == 0 then
			warn(`Ledger: rejected transaction, leg {Index} needs {KeyIssue(Target)} and a string Kind`)
			return Future.Completed(false)
		end

		Mapped[Index] = {
			Key = Resolved,
			Kind = Leg.Kind,
			Fields = Leg.Fields,
			Wrapper = Target.Live.Wrapper,
			TxStore = Target.Live.TxWrapper,
			Reducer = Target.Live.Reducer,
			Initial = Target.Live.Initial,
			Migrations = Target.Live.Migrations,
		}
	end

	local Live = self.Live
	return Future.New(function(): boolean
		return Tx.Drive(Live.Wrapper, Live.TxWrapper, Live.Reducer, Live.Initial, Live.Migrations, Mapped)
	end)
end

function DataStore.RecoverTransfers(self: DataStore, Key: KeyLike): Future<()>
	local Live = self.Live
	if not Live.Options.Balance then
		return Future.Errored("RecoverTransfers needs the store to name a Balance field, like Balance = \"Gold\"")
	end
	local Resolved = KeyFor(self, Key)
	if not Resolved then
		return Future.Errored(`RecoverTransfers needs {KeyIssue(self)}, got {typeof(Key)}`)
	end

	return Future.New(function()
		local Record = Log.Read(Live.Wrapper, Resolved)
		local State = Log.FoldRecord(Record, Live.Initial, Live.Reducer, Live.Migrations)
		Transfer.Recover(Live.Wrapper, Live.Reducer, Live.Initial, Live.Migrations, Resolved, State._Held)
	end)
end

function DataStore.ClearDelivered(self: DataStore, Key: KeyLike): Future<()>
	local Live = self.Live
	local Resolved = KeyFor(self, Key)
	if not Resolved then
		return Future.Errored(`ClearDelivered needs {KeyIssue(self)}, got {typeof(Key)}`)
	end

	return Future.New(function()
		Transfer.Prune(Live.Wrapper, Resolved)
	end)
end

function DataStore.Reset(self: DataStore, Key: KeyLike): Future<()>
	local Live = self.Live
	local Resolved = KeyFor(self, Key)
	if not Resolved then
		return Future.Errored(`Reset needs {KeyIssue(self)}, got {typeof(Key)}`)
	end

	local Op = MakeOp(RESET_KIND, { State = Live.Options.Default })

	return Future.New(function()
		Log.Append(Live.Wrapper, Resolved, { Op })
	end)
end

function DataStore.Erase(self: DataStore, Key: KeyLike): Future<()>
	local Live = self.Live
	local Resolved = KeyFor(self, Key)
	if not Resolved then
		return Future.Errored(`Erase needs {KeyIssue(self)}, got {typeof(Key)}`)
	end

	if Live.Keys == "Player" then
		local Online: any = Players:GetPlayerByUserId(Key :: any)
		if Online then
			warn(`Ledger: erasing {Resolved} while they are in this server, their session will resurrect a partial record`)
		end
	end

	return Future.New(function()
		local Ok, Reason = Live.Wrapper:RemoveAsync(Resolved)
		if not Ok then
			error(Reason)
		end
	end)
end

table.freeze(DataStore)

local Ledger = {}

function Ledger.New<D>(Options: NewOptions<D>): Store<D>
	local Config = Options :: any
	Vet(Config)
	assert(
		not Claimed[Config.Name] and not Claimed[Config.Name .. "_Tx"],
		`a store named '{Config.Name}' already exists in this server`
	)
	Claimed[Config.Name] = true
	Claimed[Config.Name .. "_Tx"] = true

	local Base = Config.Reducer
	if Config.Balance then
		Base = Transfer.Wrap(Base, Config.Balance)
	end

	local Keys: Types.KeysMode = Config.Keys or "Player"
	local Initial = MakeInitial(Config.Default)
	local Built: DataStore = setmetatable({
		Live = {
			Options = Config,
			Reducer = WrapSystem(Base, Initial),
			Wrapper = DataStoreWrapper.New(Config.Name),
			TxWrapper = DataStoreWrapper.New(Config.Name .. "_Tx"),
			Initial = Initial,
			Migrations = Config.Migrations or {},
			Keys = Keys,
			Loaded = {},
			Waiters = {},
			Leaving = {},
		},
	}, DataStore)

	table.insert(Instances, Built)
	return Built :: any
end

function Ledger.CloseAll()
	for _, Built in Instances do
		Built.Live.Wrapper:SkipAllQueuesToLastEnqueued()
		Built.Live.Wrapper.Attempts = SHUTDOWN_ATTEMPTS
		Built.Live.TxWrapper:SkipAllQueuesToLastEnqueued()
		Built.Live.TxWrapper.Attempts = SHUTDOWN_ATTEMPTS
	end

	for _, Built in Instances do
		for UserId, Entry in Built.Live.Loaded do
			Built.Live.Loaded[UserId] = nil
			task.cancel(Entry.Ticker)
			Save(Entry.Active, UserId)
		end
	end

	local Jobs: { Future<()> } = {}
	for Job in InFlight do
		table.insert(Jobs, Job)
	end
	for _, Job in Jobs do
		Job:Wait()
		InFlight[Job] = nil
	end
end

return table.freeze(Ledger)
