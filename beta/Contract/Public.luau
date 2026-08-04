--!strict
--!optimize 2

--[=[
	Public: The only types that a game can name.
	
	A leg names a store, and a store takes legs. Both shapes are therefore in one file.
	Two files would have to require each other.
	
	Return type: An empty table. The types are Store, Live, Config, TxLeg and HoldOptions.
	Example usage:
		local Public = require("./Public")
		type Store<D> = Public.Store<D>
--]=]

local Future = require("../Util/Future")
local Observer = require("../Util/Observer")
local Op = require("./Op")
local Reasons = require("./Reason")

type Future<T...> = Future.Future<T...>
type Observer<T> = Observer.Observer<T>

type Op = Op.Op
type Record<S> = Op.Record<S>
type HistoryEntry = Op.HistoryEntry
type KeyLike = Op.KeyLike
type KeysMode = Op.KeysMode
type Migration = Op.Migration
type Reason = Reasons.Reason

export type TxLeg = {
	Store: Store<any>?,
	UserId: number?,
	Key: string?,
	Kind: string,
	Fields: { [any]: any }?
}

export type HoldOptions = {
	Hold: number?,
	To: KeyLike?
}

export type Live<S> = {
	read LogSize: number,
	read LogBytes: number,

	Get: (self: Live<S>) -> S,
	Apply: (self: Live<S>, Kind: string, Fields: { [any]: any }?) -> (boolean, Reason?),
	Commit: (self: Live<S>, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	CommitOp: (self: Live<S>, Op: Op) -> Future<boolean, Reason?>,
	Flush: (self: Live<S>) -> Future<boolean, Reason?>,
	Compact: (self: Live<S>) -> Future<boolean, Reason?>,
	Release: (self: Live<S>) -> Future<boolean, Reason?>,
	Observe: (self: Live<S>) -> Observer<S>,
	DidApply: (self: Live<S>, Id: string) -> boolean
}

export type Store<D> = {
	Load: (self: Store<D>, Player: Player) -> (),
	Unload: (self: Store<D>, Player: Player) -> (),
	Get: (self: Store<D>, Player: Player) -> Live<D>?,
	Expect: (self: Store<D>, Player: Player) -> Live<D>,
	IsLoaded: (self: Store<D>, Player: Player) -> boolean,
	WaitForLoaded: (self: Store<D>, Player: Player) -> Live<D>?,
	Read: (self: Store<D>, Player: Player) -> D?,
	Peek: (self: Store<D>, Key: KeyLike) -> Future<D?, Reason?>,
	Inspect: (self: Store<D>, Key: KeyLike) -> Future<Record<D>?, Reason?>,
	DidApply: (self: Store<D>, Key: KeyLike, Id: string) -> Future<boolean?, Reason?>,
	History: (self: Store<D>, Key: KeyLike, Limit: number?) -> Future<{ HistoryEntry }?, Reason?>,
	PeekVersion: (self: Store<D>, Key: KeyLike, Version: string) -> Future<D?, Reason?>,
	Edit: (self: Store<D>, Key: KeyLike, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	Transfer: (self: Store<D>, From: KeyLike, To: KeyLike, Amount: number, Id: string?) -> Future<boolean, Reason?>,
	Bump: (self: Store<D>, Name: string, Field: string, Amount: number) -> Future<boolean, Reason?>,
	Total: (self: Store<D>, Name: string, Field: string) -> Future<number?, Reason?>,
	Reserve: (self: Store<D>, Key: KeyLike, Field: string, Amount: number, Id: string, Options: HoldOptions?) -> Future<boolean, Reason?>,
	Confirm: (self: Store<D>, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Release: (self: Store<D>, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Grant: (self: Store<D>, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Tx: (self: Store<D>, Id: string, Legs: { TxLeg }) -> Future<boolean, Reason?>,
	Resettle: (self: Store<D>, Key: KeyLike) -> Future<boolean, Reason?>,
	RecoverTransfers: (self: Store<D>, Key: KeyLike) -> Future<boolean, Reason?>,
	ClearDelivered: (self: Store<D>, Key: KeyLike) -> Future<boolean, Reason?>,
	Reset: (self: Store<D>, Key: KeyLike) -> Future<boolean, Reason?>,
	Erase: (self: Store<D>, Key: KeyLike) -> Future<boolean, Reason?>,
	Destroy: (self: Store<D>) -> ()
}

export type Config<D> = {
	read Name: string,
	read Reducer: (State: D, Op: Op) -> unknown,
	read Default: D,
	read Balance: string?,
	read Migrations: { Migration }?,
	read Keys: KeysMode?,
	read OnLoadFailed: ((Player: Player, Why: Reason) -> boolean)?
}

return table.freeze({})
