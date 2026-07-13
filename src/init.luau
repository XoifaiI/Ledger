--!strict
--!optimize 2

--[=[
    Ledger: player data as a ledger, not a document. state is a pure fold of an append
    only op log, every change is a validated intent, and there are no session locks
    anywhere. loads a session per player, autosaves it, and covers the cross-server
    side: peek, edit, transfer, transactions, history and recovery.

    the boot owns the lifecycle: Load on join, Unload on leave, CloseAll on close.

    Return type: singleton service, cast to Store<D> by a game
    Example usage:
        local Ledger = require(ServerStorage.Ledger)
        Ledger:Configure({ Name = "PlayerData", Reducer = Reducer, Default = Default })
        Ledger:Load(Player)
--]=]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Future = require("@self/Util/Future")
local SetInterval = require("@self/Util/SetInterval")
local TableUtil = require("@self/Util/TableUtil")
local DataStoreWrapper = require("@self/Util/DataStoreWrapper")
local Log = require("@self/Log")
local MakeOp = require("@self/MakeOp")
local IsStorable = require("@self/Storable")
local Session = require("@self/Session")
local Transfer = require("@self/Transfer")
local Tx = require("@self/Tx")
local Types = require("@self/Types")

type Op = Types.Op
type Session<S> = Types.Session<S>
type Future<T...> = Future.Future<T...>

export type Store<D> = Types.Store<D>

type Config = Types.Config
type Runtime = Types.Runtime
type DataStoreImpl = Types.DataStoreImpl
type DataStore = Types.DataStore

local AUTOSAVE_INTERVAL = 30
local COMPACT_THRESHOLD = 128
local COMPACT_BYTES = 1024 * 1024
local RELEASE_ATTEMPTS = 3
local SHUTDOWN_ATTEMPTS = 2

local RESET_KIND = "__Reset"

type Entry = {
	Active: Session<any>,
	Ticker: thread,
}

local Loaded: { [number]: Entry } = {}
local Waiters: { [number]: { thread } } = {}

local function MakeInitial(Default: any): any
	return TableUtil.DeepFreeze(TableUtil.DeepCopy(Default))
end

local function WrapSystem(GameReducer: Types.Reducer<any>): Types.Reducer<any>
	local function Combined(State: any, Op: Op): any?
		if Op.Kind ~= RESET_KIND then
			return GameReducer(State, Op)
		end

		local Snapshot = Op.State
		if type(Snapshot) ~= "table" then
			return nil
		end

		local Next = TableUtil.DeepCopy(Snapshot)
		Next._Purchases = State._Purchases
		Next._Received = State._Received
		return Next
	end

	return Combined
end

local function Wake(UserId: number, Active: Session<any>?)
	local List = Waiters[UserId]
	if not List then
		return
	end
	Waiters[UserId] = nil
	for _, Thread in List do
		task.spawn(Thread, Active)
	end
end

local InFlight: { [Future<()>]: boolean } = {}

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

local function ExpectLive(self: DataStore, What: string): Runtime
	return assert(self.Live, `Ledger not configured before {What}`)
end

local function ValidId(UserId: any): boolean
	return type(UserId) == "number" and UserId == UserId // 1 and UserId > 0
end

local function Vet(Options: Config)
	assert(type(Options) == "table", "Configure takes an options table")
	assert(
		type(Options.Name) == "string" and #Options.Name > 0 and #Options.Name <= 50,
		"Configure needs Name, a datastore name of 1 to 50 characters"
	)
	assert(type(Options.Reducer) == "function", "Configure needs Reducer, a (State, Op) -> State? function")
	assert(type(Options.Default) == "table", "Configure needs Default, the fresh profile table")

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
end

function DataStore.Configure(self: DataStore, Options: Config)
	Vet(Options)
	self.Live = {
		Options = Options,
		Reducer = WrapSystem(Options.Reducer),
		Wrapper = DataStoreWrapper.New(Options.Name),
		TxWrapper = DataStoreWrapper.New(Options.Name .. "_Tx"),
		Initial = MakeInitial(Options.Default),
		Migrations = Options.Migrations or {},
	}
end

function DataStore.Load(self: DataStore, Player: Player)
	local Live = ExpectLive(self, "Load")

	local UserId = Player.UserId
	if Loaded[UserId] then
		warn(`Ledger: {Player.Name} already has a live session, ignoring the second Load`)
		return
	end

	local Job = Session.Load(Live.Wrapper, tostring(UserId), Live.Reducer, Live.Initial, Live.Migrations, Live.TxWrapper)
	local Active = Job:Wait()

	if not Job:Happened() or not Active then
		Player:Kick("Your data failed to load, please rejoin")
		Wake(UserId, nil)
		return
	end

	local LastFailed = false
	local Ticker = SetInterval(AUTOSAVE_INTERVAL, function()
		local Entry = Loaded[UserId]
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

	Loaded[UserId] = { Active = Active, Ticker = Ticker }
	Wake(UserId, Active)

	local Held = Active:Get()._Held
	if type(Held) == "table" and next(Held) then
		task.spawn(Transfer.Recover, Live.Wrapper, UserId, Held)
	end
end

function DataStore.Unload(self: DataStore, Player: Player)
	local UserId = Player.UserId
	local Entry = Loaded[UserId]
	if not Entry then
		Wake(UserId, nil)
		return
	end

	Loaded[UserId] = nil
	task.cancel(Entry.Ticker)

	local Job = Save(Entry.Active, UserId)
	Job:Wait()
	InFlight[Job] = nil
end

function DataStore.CloseAll(self: DataStore)
	local Live = self.Live
	if Live then
		Live.Wrapper:SkipAllQueuesToLastEnqueued()
		Live.Wrapper.Attempts = SHUTDOWN_ATTEMPTS
	end

	for UserId, Entry in Loaded do
		Loaded[UserId] = nil
		task.cancel(Entry.Ticker)
		Save(Entry.Active, UserId)
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

function DataStore.Get(self: DataStore, Player: Player): Session<any>?
	local Entry = Loaded[Player.UserId]
	return if Entry then Entry.Active else nil
end

function DataStore.Expect(self: DataStore, Player: Player): Session<any>
	local Entry = Loaded[Player.UserId]
	return assert(Entry and Entry.Active, `data for {Player.Name} is not loaded`)
end

function DataStore.IsLoaded(self: DataStore, Player: Player): boolean
	return Loaded[Player.UserId] ~= nil
end

function DataStore.WaitForLoaded(self: DataStore, Player: Player): Session<any>?
	local Entry = Loaded[Player.UserId]
	if Entry then
		return Entry.Active
	end
	if not Player.Parent then
		return nil
	end

	local List = Waiters[Player.UserId]
	if not List then
		List = {}
		Waiters[Player.UserId] = List
	end
	table.insert(List, coroutine.running())
	return coroutine.yield()
end

function DataStore.Read(self: DataStore, Player: Player): any
	local Entry = Loaded[Player.UserId]
	return if Entry then Entry.Active:Get() else nil
end

function DataStore.Peek(self: DataStore, UserId: number): Future<any>
	local Live = ExpectLive(self, "Peek")
	if not ValidId(UserId) then
		return Future.Errored(`Peek needs a positive integer UserId, got {typeof(UserId)}`)
	end

	return Future.New(function(): any
		local Record = Log.Read(Live.Wrapper, tostring(UserId))
		return Log.FoldRecord(Record, Live.Initial, Live.Reducer, Live.Migrations)
	end)
end

function DataStore.History(self: DataStore, UserId: number, Limit: number?): Future<{ Types.HistoryEntry }>
	local Live = ExpectLive(self, "History")
	if not ValidId(UserId) then
		return Future.Errored(`History needs a positive integer UserId, got {typeof(UserId)}`)
	end

	return Future.New(function(): { Types.HistoryEntry }
		local Ok, Pages = Live.Wrapper:ListVersionsAsync(
			tostring(UserId),
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

function DataStore.PeekVersion(self: DataStore, UserId: number, Version: string): Future<any>
	local Live = ExpectLive(self, "PeekVersion")
	if not ValidId(UserId) or type(Version) ~= "string" or #Version == 0 then
		return Future.Errored("PeekVersion needs a positive integer UserId and a Version string from History")
	end

	return Future.New(function(): any
		local Record = Log.ReadVersion(Live.Wrapper, tostring(UserId), Version)
		return Log.FoldRecord(Record, Live.Initial, Live.Reducer, Live.Migrations)
	end)
end

function DataStore.Edit(self: DataStore, UserId: number, Kind: string, Fields: { [any]: any }?): Future<()>
	local Live = ExpectLive(self, "Edit")

	if not ValidId(UserId) then
		warn(`Ledger: rejected edit '{tostring(Kind)}', it needs a positive integer UserId, got {typeof(UserId)}`)
		return Future.Completed()
	end

	local Op = MakeOp(Kind, Fields)
	local Storable, Reason = IsStorable.Op(Op)
	if not Storable then
		warn(`Ledger: rejected edit '{Kind}', {Reason}`)
		return Future.Completed()
	end

	return Future.New(function()
		local Record = Log.Append(Live.Wrapper, tostring(UserId), { Op })
		if #Record.Ops >= COMPACT_THRESHOLD then
			Log.Compact(Live.Wrapper, tostring(UserId), Live.Reducer, Live.Initial, Live.Migrations)
		end
	end)
end

function DataStore.Transfer(self: DataStore, FromUserId: number, ToUserId: number, Amount: number): Future<boolean>
	local Live = ExpectLive(self, "Transfer")

	if not ValidId(FromUserId) or not ValidId(ToUserId) or FromUserId == ToUserId then
		warn("Ledger: Transfer needs two different positive integer UserIds")
		return Future.Completed(false)
	end

	return Future.New(function(): boolean
		return Transfer.Drive(Live.Wrapper, Live.Reducer, Live.Initial, FromUserId, ToUserId, Amount, Live.Migrations)
	end)
end

function DataStore.Tx(self: DataStore, Legs: { Types.TxLeg }): Future<boolean>
	local Live = ExpectLive(self, "Tx")

	if type(Legs) ~= "table" then
		warn("Ledger: Tx takes an array of legs")
		return Future.Completed(false)
	end

	local Mapped: { Tx.Leg } = table.create(#Legs) :: { Tx.Leg }
	for Index, Leg in Legs do
		if type(Leg) ~= "table" or not ValidId(Leg.UserId) or type(Leg.Kind) ~= "string" or #Leg.Kind == 0 then
			warn(`Ledger: rejected transaction, leg {Index} needs a positive integer UserId and a string Kind`)
			return Future.Completed(false)
		end
		Mapped[Index] = { Key = tostring(Leg.UserId), Kind = Leg.Kind, Fields = Leg.Fields }
	end

	return Future.New(function(): boolean
		return Tx.Drive(Live.Wrapper, Live.TxWrapper, Live.Reducer, Live.Initial, Live.Migrations, Mapped)
	end)
end

function DataStore.RecoverTransfers(self: DataStore, UserId: number): Future<()>
	local Live = ExpectLive(self, "RecoverTransfers")
	if not ValidId(UserId) then
		return Future.Errored(`RecoverTransfers needs a positive integer UserId, got {typeof(UserId)}`)
	end

	return Future.New(function()
		local Record = Log.Read(Live.Wrapper, tostring(UserId))
		local State = Log.FoldRecord(Record, Live.Initial, Live.Reducer, Live.Migrations)
		Transfer.Recover(Live.Wrapper, UserId, State._Held)
	end)
end

function DataStore.ClearDelivered(self: DataStore, UserId: number): Future<()>
	local Live = ExpectLive(self, "ClearDelivered")
	if not ValidId(UserId) then
		return Future.Errored(`ClearDelivered needs a positive integer UserId, got {typeof(UserId)}`)
	end

	return Future.New(function()
		Transfer.Prune(Live.Wrapper, UserId)
	end)
end

function DataStore.Reset(self: DataStore, UserId: number): Future<()>
	local Live = ExpectLive(self, "Reset")
	if not ValidId(UserId) then
		return Future.Errored(`Reset needs a positive integer UserId, got {typeof(UserId)}`)
	end

	local Op = MakeOp(RESET_KIND, { State = Live.Options.Default })

	return Future.New(function()
		Log.Append(Live.Wrapper, tostring(UserId), { Op })
	end)
end

function DataStore.Erase(self: DataStore, UserId: number): Future<()>
	local Live = ExpectLive(self, "Erase")
	if not ValidId(UserId) then
		return Future.Errored(`Erase needs a positive integer UserId, got {typeof(UserId)}`)
	end

	local Online: any = Players:GetPlayerByUserId(UserId :: any)
	if Online then
		warn(`Ledger: erasing {UserId} while they are in this server, their session will resurrect a partial record`)
	end

	return Future.New(function()
		local Ok, Reason = Live.Wrapper:RemoveAsync(tostring(UserId))
		if not Ok then
			error(Reason)
		end
	end)
end

table.freeze(DataStore)
return setmetatable({ Live = nil :: Runtime? }, DataStore) :: DataStore
