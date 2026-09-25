--!strict
--!optimize 2

--[=[

	Store: The store object that Ledger.New gives back.

	One store holds one datastore name, every key under it, and every session live on this server.
	New builds one, with its reducer stack, its wrappers and its maps. Destroy takes it down and saves
	every session it holds. The six requires with no name on them put the rest of the methods onto the
	class. Api/Players holds the sessions it keeps for the players on this server.

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
local DataStoreWrapper = require("../Util/DataStoreWrapper")
local MemoryStoreWrapper = require("../Util/MemoryStoreWrapper")
local Lru = require("../Util/Lru")
local Ids = require("../Encode/Ids")
local Reasons = require("../Core/Constants/Reasons")
local Bookings = require("../Core/Constants/Bookings")
local Follows = require("../Core/Constants/Follows")
local Shards = require("../Core/Constants/Shards")
local Transactions = require("../Core/Constants/Transactions")
local Shapes = require("../Core/Shapes")
local Api = require("../Core/Api")
local Apply = require("../Record/Apply")
local Layers = require("../Layers")
local Registry = require("./Registry")
local Store = require("./Class")
local Types = require("./Types")

require("./Shared")
require("./Api/Read")
require("./Api/Admin")
require("./Api/Ops")
require("./Api/Follow")
require("./Api/Players")

type Future<T...> = Future.Future<T...>
type Reason = Reasons.Reason
type Migration = Shapes.Migration
type Config<D> = Api.Config<D>
type Store = Types.Store<any>

local RECENT_TALLIES = 256
local KEPT_COPIES = 256
local PROBE_KIND = "LedgerUnknownKind"

local TX_SUFFIX = Transactions.SUFFIX

local function MakeInitial(Default: any): any
	return TableUtil.DeepFreeze(TableUtil.DeepCopy(Default))
end

local function Probed(Name: string, Reducer: Shapes.Reducer<any>, Initial: any)
	if Apply(Reducer, Initial, { Id = "probe", Kind = PROBE_KIND }) == nil then
		return
	end
	warn(`Ledger: the reducer for '{Name}' gave back a state for a kind it does not know. give back nil for a kind you do not handle`)
end

local function Batching(Every: number?): Types.Batched?
	if Every == nil then
		return nil
	end
	return { Every = Every, Queued = {}, Flushing = {}, Ticker = nil }
end

local function Rotation(): Types.Reaping
	return { Resume = nil, Shard = 0, Back = 2 }
end

local function Metering(): Types.Meter
	return { Skipped = 0, At = 0, Records = 0, Markers = 0, Swollen = 0, Said = 0, Unbooked = 0, Crowded = 0, Uncopied = 0 }
end

local function Ticking(Built: Store)
	local Bumps = Built.Bumps
	if Bumps == nil then
		return
	end

	local Turn = Built.Wrapper.Scheduler
	Bumps.Ticker = SetInterval(Turn, Bumps.Every, function()
		Built:Flushed()
	end, Turn.Roll() * Bumps.Every)
end

local function New<D>(Config: Config<D>): Api.Store<D>
	local Marked = `{Config.Name}{TX_SUFFIX}`
	assert(not Registry.Claimed[Config.Name] and not Registry.Claimed[Marked], `a store named '{Config.Name}' already exists in this server`)
	Registry.Claimed[Config.Name] = true
	Registry.Claimed[Marked] = true

	local Turn = Clock.Held()
	local Asked = Config.Mock
	local Faked = Config.Hook == nil and (Asked == true or type(Asked) == "table")
	local Hook = Config.Hook or (if Asked then Registry.Mock(if type(Asked) == "table" then Asked else nil) else Registry.Defaults.Hook)
	if Faked then
		warn(`Ledger: store '{Config.Name}' is on a fake datastore, nothing it saves outlives this server`)
	end

	local Keys = (Config.Keys or "Player") :: Shapes.KeysMode
	local Cached = Hook.Cache ~= nil
	local Tallies = if Cached then MemoryStoreWrapper.New(Shards.MAP, Turn, Hook) else nil
	local Leases = if Cached then MemoryStoreWrapper.New(Transactions.LEASE_MAP, Turn, Hook) else nil
	local Holds = if Cached then MemoryStoreWrapper.New(Bookings.MAP, Turn, Hook) else nil
	local Copier = if Cached then MemoryStoreWrapper.New(Follows.MAP, Turn, Hook) else nil
	if Tallies == nil then
		warn(
			`Ledger: store '{Config.Name}' is on a hook with no MemoryStore, so every total is read from its shards, a followed key is read from the datastore on every tick, transactions on one key race rather than queue, and nothing can be reserved`
		)
	end

	local Initial = MakeInitial(Config.Default)
	local Steps: { Migration } = Config.Migrations or {}
	local Reducer, Handled = Layers.Built(Config.Balance, Config.Reducer :: any, Initial, Steps)
	Probed(Config.Name, Config.Reducer :: any, Initial)

	local Body: Types.Fields<D> = {
		Options = Config :: any,
		Reducer = Reducer,
		Wrapper = DataStoreWrapper.New(Config.Name, Turn, Hook),
		TxWrapper = DataStoreWrapper.New(Marked, Turn, Hook),
		Tallies = Tallies,
		Leases = Leases,
		Bookings = Holds,
		Copier = Copier,
		Copies = Lru.New(KEPT_COPIES),
		Followed = {},
		Recent = Lru.New(RECENT_TALLIES),
		Bumped = 0,
		Initial = Initial,
		Migrations = Steps,
		Handles = Handled,
		Shards = Config.Shards or Shards.SHARDS,
		Bumps = Batching(Config.BumpEvery),
		Books = nil,
		Shaped = nil,
		Keys = Keys,
		Loaded = {},
		Waiters = {},
		Loads = {},
		Latest = {},
		Saving = {},
		Node = Ids.Home(),
		Sweep = Registry.Sweep(),
		Sweeping = nil,
		Staleness = Observer.New(true) :: Observer.Subject<string>,
		Meter = Metering(),
		Reaping = Rotation(),
		Closed = false,
	}
	local Built: Store = setmetatable(Body :: any, Store)

	table.insert(Registry.Stores, Built)
	Built.Sweep:Adopt(Built:Swept())
	Ticking(Built)
	return Built
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
	self:Unfollowed()

	local Bumps = self.Bumps
	if Bumps ~= nil and Bumps.Ticker ~= nil then
		self.Wrapper.Scheduler.Cancel(Bumps.Ticker)
		Bumps.Ticker = nil
	end
	self:Flushed()

	local Jobs: { Future<boolean, Reason?> } = {}
	for UserId, Entry in self.Loaded do
		self.Loaded[UserId] = nil
		self.Wrapper.Scheduler.Cancel(Entry.Ticker)
		table.insert(Jobs, self:Save(Entry.Active))
	end
	table.clear(self.Latest)

	for Waiting in self.Waiters do
		self:Wake(Waiting, nil)
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
