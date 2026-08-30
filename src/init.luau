--!strict
--!optimize 2

--[=[

	Ledger: Player data as a ledger, and not as a document.

	State is a pure fold of an append only log of ops, and there are no session locks. This file is the
	whole surface a game can reach: New and NewTyped build a store, Use chooses the scheduler and
	datastore stores are built with, Sweep runs a recovery pass, and CloseAll saves everything on the
	way down.

	Return type: A table with Reason, New, NewTyped, Use, UseMock, Sweep and CloseAll.
	Example usage:
		local Ledger = require(ServerStorage.Ledger)
		local Bank = Ledger.New({ Name = "Bank", Default = { Gold = 0 }, Reducer = Reducer })
		local Shop = Ledger.NewTyped<<Profile, { Buy: { Item: string } }>>(Options)
--]=]

local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "Ledger runs on the server, only the server can reach a datastore")

local Future = require("@self/Util/Future")
local Observer = require("@self/Util/Observer")
local Shapes = require("@self/Core/Shapes")
local Api = require("@self/Core/Api")
local Reasons = require("@self/Core/Constants/Reasons")
local TypeFunctions = require("@self/Core/TypeFunctions")
local Engine = require("@self/Util/Engine")
local Memory = require("@self/Hooks/Memory")
local Mock = require("@self/Mock")
local Tx = require("@self/Protocol/Tx")
local Registry = require("@self/Store/Registry")
local Store = require("@self/Store/Store")
local Validate = require("@self/Store/Validate")

export type Store<D> = Api.Store<D>
export type TypedStore<D, O> = Api.TypedStore<D, O>
export type Session<S> = Api.Live<S>
export type TypedSession<S, O> = Api.TypedLive<S, O>
export type Config<D> = Api.Config<D>
export type TypedConfig<D, O> = Api.TypedConfig<D, O>
export type OpMap = Api.OpMap
export type TxLeg = Api.TxLeg
export type HoldOptions = Api.HoldOptions
export type Op<O = any> = TypeFunctions.OpUnion<O>
export type OpOf<O, K> = TypeFunctions.OpOf<O, K>
export type Reducer<S, O = any> = (State: S, Op: TypeFunctions.OpUnion<O>) -> S?
export type Record<D> = Shapes.Record<D>
export type Future<T...> = Future.Future<T...>
export type Observer<T> = Observer.Observer<T>
export type KeyLike = Shapes.KeyLike
export type KeysMode = Shapes.KeysMode
export type Migration = Shapes.Migration
export type HistoryEntry = Shapes.HistoryEntry
export type Reason = Reasons.Reason

export type Export = {
	read Reason: typeof(Reasons),

	read New: <D>(Options: Config<D>) -> Store<D>,
	read NewTyped: <D, O>(Options: TypedConfig<D, O>) -> TypedStore<D, O>,
	read Use: (Scheduler: Engine.Scheduler?, Hook: Engine.Hook?) -> (),
	read UseMock: (Options: Mock.Options?) -> Memory.Memory,
	read Sweep: () -> (),
	read CloseAll: () -> (),
}

local SHUTDOWN_ATTEMPTS = 2

local function New<D>(Options: Config<D>): Store<D>
	Validate(Options)
	return Store.New(Options)
end

local function NewTyped<D, O>(Options: TypedConfig<D, O>): TypedStore<D, O>
	return New(Options :: any) :: any
end

local function Use(Scheduler: Engine.Scheduler?, Hook: Engine.Hook?)
	Registry.Use(Scheduler, Hook)
end

local function UseMock(Options: Mock.Options?): Memory.Memory
	local Held = Registry.Defaults.Scheduler
	local Hook = Memory.New(Held, Options)
	Registry.Use(Held, Hook)
	return Hook
end

local function Sweeps(Visit: (Registry.Sweeper) -> ())
	local Shared = Registry.Sweep()
	local Seen: { [Registry.Sweeper]: boolean } = { [Shared] = true }
	Visit(Shared)

	for _, Held in Registry.Stores do
		if Seen[Held.Sweep] then
			continue
		end
		Seen[Held.Sweep] = true
		Visit(Held.Sweep)
	end
end

local function Sweep()
	Sweeps(function(Held: Registry.Sweeper)
		Held:Pass()
	end)
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
			Held.Wrapper.Scheduler.Cancel(Entry.Ticker)
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
	Sweeps(function(Held: Registry.Sweeper)
		Held:Stop()
	end)
	Hurry()
	Release()
	Settle()
	Registry.Shutting.Now = false
end

return table.freeze({
	Reason = Reasons,

	New = New,
	NewTyped = NewTyped,
	Use = Use,
	UseMock = UseMock,
	Sweep = Sweep,
	CloseAll = CloseAll,
}) :: Export
