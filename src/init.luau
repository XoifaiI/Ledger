--!strict
--!optimize 2

--[=[
	Ledger: Player data as a ledger, and not as a document.
	
	The state is a pure fold of an append only log of ops. There are no session locks.
	This file is the whole surface that a game can reach.
	CloseAll cuts each queue down to its last write and gives it fewer tries. A shutdown has seconds,
	and a queue of retries would spend all of them on one key.
	
	Return type: A table with Reason, New, UseMock, UseReal, UseClock, Sweep and CloseAll.
	Example usage:
		local Ledger = require(ServerStorage.Ledger)
		local Bank = Ledger.New({ Name = "Bank", Default = { Gold = 0 }, Reducer = Reducer })
--]=]

local Future = require("@self/Util/Future")
local DataStoreWrapper = require("@self/Util/DataStoreWrapper")
local Clock = require("@self/Util/Clock")
local Contract = require("@self/Contract/Op")
local Public = require("@self/Contract/Public")
local Reasons = require("@self/Contract/Reason")
local Mock = require("@self/Mock")
local Tx = require("@self/Protocol/Tx")
local Registry = require("@self/Store/Registry")
local Store = require("@self/Store/Store")
local Vet = require("@self/Store/Vet")

type Future<T...> = Future.Future<T...>

export type Store<D> = Public.Store<D>
export type Session<S> = Public.Live<S>
export type Config<D> = Public.Config<D>
export type TxLeg = Public.TxLeg
export type HoldOptions = Public.HoldOptions
export type Op = Contract.Op
export type Reducer<S> = Contract.Reducer<S>
export type KeyLike = Contract.KeyLike
export type KeysMode = Contract.KeysMode
export type Migration = Contract.Migration
export type HistoryEntry = Contract.HistoryEntry
export type Reason = Reasons.Reason

export type Export = {
	read Reason: typeof(Reasons),

	read New: <D>(Options: Config<D>) -> Store<D>,
	read UseMock: (Options: Mock.Options?) -> Mock.Service,
	read UseReal: () -> (),
	read UseClock: (Reads: (() -> number)?, Sleeps: ((Seconds: number) -> ())?) -> (),
	read Sweep: () -> (),
	read CloseAll: () -> ()
}

local SHUTDOWN_ATTEMPTS = 2

local function New<D>(Options: Config<D>): Store<D>
	Vet(Options)
	return Store.New(Options)
end

local function UseMock(Options: Mock.Options?): Mock.Service
	if DataStoreWrapper.Swapped() and #Registry.Stores > 0 then
		warn(
			`Ledger: UseMock was called again while {#Registry.Stores} store(s) were live, so they are all on a fresh empty datastore now and nothing they wrote before this reads back. call it one time, before you build your stores`
		)
	end

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

local function UseClock(Reads: (() -> number)?, Sleeps: ((Seconds: number) -> ())?)
	Clock.Set(Reads, Sleeps)
end

local function Sweep()
	Registry.Sweep():Pass()
end

local function Hurry()
	for _, Held in Registry.Stores do
		Held.Wrapper:SkipAllQueuesToLastEnqueued()
		Held.Wrapper.Attempts = SHUTDOWN_ATTEMPTS
		Held.TxWrapper:SkipAllQueuesToLastEnqueued()
		Held.TxWrapper.Attempts = SHUTDOWN_ATTEMPTS
	end
	Tx.ShutdownHomes(SHUTDOWN_ATTEMPTS)
end

local function Release()
	for _, Held in Registry.Stores do
		for UserId, Entry in Held.Loaded do
			Held.Loaded[UserId] = nil
			task.cancel(Entry.Ticker)
			Held:Save(Entry.Active)
		end
	end
end

local function Settle()
	for _, Held in Registry.Stores do
		local Jobs: { Future<boolean, Reason?> } = {}
		for Job in Held.Saving do
			table.insert(Jobs, Job)
		end
		for _, Job in Jobs do
			Job:Wait()
			Held.Saving[Job] = nil
		end
	end
end

local function CloseAll()
	Registry.Shutting.Now = true
	Registry.Sweep():Stop()
	Hurry()
	Release()
	Settle()
	Registry.Shutting.Now = false
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
