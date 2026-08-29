--!strict
--!optimize 2

--[=[
	Api: The only types that a game can name.

	A leg names a store, and a store takes legs. Both shapes are therefore in one file, because two
	files would have to require each other.
	Store.New hands its store back without a cast, so the checker holds these shapes against what a
	store actually is. That check is only had by leaving self open, since a store's own methods read
	fields this file does not name.
	A store comes in two views. Store takes any kind with any fields, and TypedStore carries one call
	shape per kind a game named. Both take the kind and the fields as two arguments, so a game moves
	between them without touching a call site. Everything that does not take an op is declared once
	and shared, and the foot of this file fails the build if the two ever drift apart.

	Return type: An empty table. The types are Store, TypedStore, Live, TypedLive, Config, TypedConfig, OpMap, TxLeg and HoldOptions.
	Example usage:
		local Api = require("./Api")
		type Store<D> = Api.Store<D>
--]=]

local Engine = require("../Util/Engine")
local Future = require("../Util/Future")
local Observer = require("../Util/Observer")
local Shapes = require("./Shapes")
local Reasons = require("./Reasons")
local TypeFunctions = require("./TypeFunctions")

type Future<T...> = Future.Future<T...>
type Observer<T> = Observer.Observer<T>

type Op = Shapes.Op
type Record<S> = Shapes.Record<S>
type HistoryEntry = Shapes.HistoryEntry
type KeyLike = Shapes.KeyLike
type KeysMode = Shapes.KeysMode
type Migration = Shapes.Migration
type Reason = Reasons.Reason

export type OpMap = { [string]: { [any]: any } }

export type TxLeg = {
	Store: Store<any>?,
	UserId: number?,
	Key: string?,
	Kind: string,
	Fields: { [any]: any }?,
}

export type HoldOptions = {
	Hold: number?,
	To: KeyLike?,
}

type LiveCommon<S> = {
	read LogSize: number,
	read LogBytes: number,

	Get: (self: any) -> S,
	Flush: (self: any) -> Future<boolean, Reason?>,
	Compact: (self: any) -> Future<boolean, Reason?>,
	Release: (self: any) -> Future<boolean, Reason?>,
	Observe: (self: any) -> Observer<S>,
	DidApply: (self: any, Id: string) -> boolean,
}

export type Live<S> = LiveCommon<S> & {
	Apply: (self: any, Kind: string, Fields: { [any]: any }?) -> (boolean, Reason?),
	Commit: (self: any, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	CommitOp: (self: any, Op: Op) -> Future<boolean, Reason?>,
}

export type TypedLive<S, O> = LiveCommon<S> & {
	Apply: TypeFunctions.Overloads<O, (any) -> (boolean, Reason?)>,
	Commit: TypeFunctions.Overloads<O, (any) -> Future<boolean, Reason?>>,
	CommitOp: (self: any, Op: TypeFunctions.OpUnion<O>) -> Future<boolean, Reason?>,
}

type StoreCommon<D, F> = {
	Load: (self: any, Player: Player) -> (),
	Unload: (self: any, Player: Player) -> (),
	IsLoaded: (self: any, Player: Player) -> boolean,
	Read: (self: any, Player: Player) -> D?,
	Peek: (self: any, Key: KeyLike) -> Future<D?, Reason?>,
	Inspect: (self: any, Key: KeyLike) -> Future<Record<D>?, Reason?>,
	DidApply: (self: any, Key: KeyLike, Id: string) -> Future<boolean?, Reason?>,
	History: (self: any, Key: KeyLike, Limit: number?) -> Future<{ HistoryEntry }?, Reason?>,
	PeekVersion: (self: any, Key: KeyLike, Version: string) -> Future<D?, Reason?>,
	Transfer: (self: any, From: KeyLike, To: KeyLike, Amount: number, Id: string?) -> Future<boolean, Reason?>,
	Bump: (self: any, Name: string, Field: F, Amount: number) -> Future<boolean, Reason?>,
	Total: (self: any, Name: string, Field: F) -> Future<number?, Reason?>,
	Reserve: (self: any, Key: KeyLike, Field: F, Amount: number, Id: string, Options: HoldOptions?) -> Future<boolean, Reason?>,
	Confirm: (self: any, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Release: (self: any, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Grant: (self: any, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Resettle: (self: any, Key: KeyLike) -> Future<boolean, Reason?>,
	RecoverTransfers: (self: any, Key: KeyLike) -> Future<boolean, Reason?>,
	ClearDelivered: (self: any, Key: KeyLike) -> Future<boolean, Reason?>,
	Reset: (self: any, Key: KeyLike) -> Future<boolean, Reason?>,
	Erase: (self: any, Key: KeyLike) -> Future<boolean, Reason?>,
	Stale: (self: any) -> Observer<string>,
	Destroy: (self: any) -> (),
}

export type Store<D> = StoreCommon<D, string> & {
	Get: (self: any, Player: Player) -> Live<D>?,
	Expect: (self: any, Player: Player) -> Live<D>,
	WaitForLoaded: (self: any, Player: Player) -> Live<D>?,
	Edit: (self: any, Key: KeyLike, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	Tx: (self: any, Id: string, Legs: { TxLeg }) -> Future<boolean, Reason?>,
}

export type TypedStore<D, O> = StoreCommon<D, TypeFunctions.NumberKeys<D>> & {
	Get: (self: any, Player: Player) -> TypedLive<D, O>?,
	Expect: (self: any, Player: Player) -> TypedLive<D, O>,
	WaitForLoaded: (self: any, Player: Player) -> TypedLive<D, O>?,
	Edit: TypeFunctions.Overloads<O, (any, KeyLike) -> Future<boolean, Reason?>>,
	Tx: (self: any, Id: string, Legs: { TxLeg }) -> Future<boolean, Reason?>,
}

type ConfigCommon<D> = {
	read Name: string,
	read Default: D,
	read Balance: string?,
	read Migrations: { Migration }?,
	read Keys: KeysMode?,
	read OnLoadFailed: ((Player: Player, Why: Reason) -> boolean)?,
	read Scheduler: Engine.Scheduler?,
	read Hook: Engine.Hook?,
}

export type Config<D> = ConfigCommon<D> & {
	read Reducer: (State: D, Op: Op) -> unknown,
}

export type TypedConfig<D, O> = ConfigCommon<D> & {
	read Reducer: (State: D, Op: TypeFunctions.OpUnion<O>) -> D?,
}

type DriftState = { Gold: number }
type DriftOps = { Buy: { Item: string } }

local _Drift: TypeFunctions.SameKeys<keyof<Store<DriftState>>, keyof<TypedStore<DriftState, DriftOps>>> & TypeFunctions.SameKeys<keyof<Live<DriftState>>, keyof<TypedLive<DriftState, DriftOps>>> & TypeFunctions.SameKeys<keyof<Config<DriftState>>, keyof<TypedConfig<DriftState, DriftOps>>> =
	true

return table.freeze({})
