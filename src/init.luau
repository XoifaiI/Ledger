--!strict
--!optimize 2

-- player data as a ledger not a document. state is a pure fold of an append only op log and there are no session locks

local Future = require("@self/Util/Future")
local DataStoreWrapper = require("@self/Util/DataStoreWrapper")
local Clock = require("@self/Clock")
local Mock = require("@self/Mock")
local Reasons = require("@self/Reason")
local Tx = require("@self/Tx")
local Types = require("@self/Types")
local Vet = require("@self/Vet")
local DataStore = require("@self/Store/DataStore")
local Registry = require("@self/Store/Registry")

type Future<T...> = Future.Future<T...>

export type Store<D> = Types.Store<D>
export type Session<S> = Types.Live<S>
export type Op = Types.Op
export type Reducer<S> = Types.Reducer<S>
export type KeyLike = Types.KeyLike
export type KeysMode = Types.KeysMode
export type Reason = Types.Reason
export type TxLeg = Types.TxLeg
export type Migration = Types.Migration
export type Config<D> = Types.Config<D>
export type HistoryEntry = Types.HistoryEntry

export type Export = {
	read Reason: typeof(Reasons),

	read New: <D>(Options: Config<D>) -> Store<D>,
	read UseMock: (Options: Mock.Options?) -> Mock.Service,
	read UseReal: () -> (),
	read UseClock: (Reads: (() -> number)?) -> (),
	read Sweep: () -> (),
	read CloseAll: () -> ()
}

local SHUTDOWN_ATTEMPTS = 2

local function New<D>(Options: Config<D>): Store<D>
	Vet(Options)
	return DataStore.New(Options)
end

local function UseMock(Options: Mock.Options?): Mock.Service
	local Service = Mock.New(Options)

	DataStoreWrapper.Use(function(Name: string): any
		return Service:GetDataStore(Name)
	end, function(Kind: Enum.DataStoreRequestType): number
		return Service:GetRequestBudgetForRequestType(Kind)
	end)

	return Service
end

local function UseReal()
	DataStoreWrapper.Use(nil, nil)
end

local function UseClock(Reads: (() -> number)?)
	Clock.Set(Reads)
end

local function Sweep()
	Registry.Sweep:Pass()
end

local function Hurry()
	for _, Store in Registry.Stores do
		Store.Wrapper:SkipAllQueuesToLastEnqueued()
		Store.Wrapper.Attempts = SHUTDOWN_ATTEMPTS
		Store.TxWrapper:SkipAllQueuesToLastEnqueued()
		Store.TxWrapper.Attempts = SHUTDOWN_ATTEMPTS
	end
	Tx.ShutdownHomes(SHUTDOWN_ATTEMPTS)
end

local function Release()
	for _, Store in Registry.Stores do
		for UserId, Entry in Store.Loaded do
			Store.Loaded[UserId] = nil
			task.cancel(Entry.Ticker)
			Store:Save(Entry.Active)
		end
	end
end

local function Settle()
	for _, Store in Registry.Stores do
		local Jobs: { Future<boolean, Types.Reason?> } = {}
		for Job in Store.Saving do
			table.insert(Jobs, Job)
		end
		for _, Job in Jobs do
			Job:Wait()
			Store.Saving[Job] = nil
		end
	end
end

local function CloseAll()
	Registry.Sweep:Stop()
	Hurry()
	Release()
	Settle()
end

return table.freeze({
	Reason = Reasons,

	New = New,
	UseMock = UseMock,
	UseReal = UseReal,
	UseClock = UseClock,
	Sweep = Sweep,
	CloseAll = CloseAll
}) :: Export
