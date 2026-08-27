--!strict
--!optimize 2

--[=[
	Public: The only types that a game can name.

	A leg names a store, and a store takes legs. Both shapes are therefore in one file.
	Two files would have to require each other.
	Store.New hands its store back without a cast, so the checker holds these shapes against what a
	store actually is and a method named here that the store does not have is an error where it is
	built. That check is only had by leaving self open. A store's own methods read fields this file
	does not name, so a self typed as the narrow shape here is one those methods could never accept,
	and the cast that used to bridge that gap checked nothing at all.

	Return type: An empty table. The types are Store, Live, Config, TxLeg and HoldOptions.
	Example usage:
		local Public = require("./Public")
		type Store<D> = Public.Store<D>
--]=]

local Future = require("../Util/Future")
local Observer = require("../Util/Observer")
local Contract = require("./Op")
local Reasons = require("./Reason")

type Future<T...> = Future.Future<T...>
type Observer<T> = Observer.Observer<T>

type Op = Contract.Op
type Record<S> = Contract.Record<S>
type HistoryEntry = Contract.HistoryEntry
type KeyLike = Contract.KeyLike
type KeysMode = Contract.KeysMode
type Migration = Contract.Migration
type Reason = Reasons.Reason

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

export type Live<S> = {
	read LogSize: number,
	read LogBytes: number,

	Get: (self: any) -> S,
	Apply: (self: any, Kind: string, Fields: { [any]: any }?) -> (boolean, Reason?),
	Commit: (self: any, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	CommitOp: (self: any, Op: Op) -> Future<boolean, Reason?>,
	Flush: (self: any) -> Future<boolean, Reason?>,
	Compact: (self: any) -> Future<boolean, Reason?>,
	Release: (self: any) -> Future<boolean, Reason?>,
	Observe: (self: any) -> Observer<S>,
	DidApply: (self: any, Id: string) -> boolean,
}

export type Store<D> = {
	Load: (self: any, Player: Player) -> (),
	Unload: (self: any, Player: Player) -> (),
	Get: (self: any, Player: Player) -> Live<D>?,
	Expect: (self: any, Player: Player) -> Live<D>,
	IsLoaded: (self: any, Player: Player) -> boolean,
	WaitForLoaded: (self: any, Player: Player) -> Live<D>?,
	Read: (self: any, Player: Player) -> D?,
	Peek: (self: any, Key: KeyLike) -> Future<D?, Reason?>,
	Inspect: (self: any, Key: KeyLike) -> Future<Record<D>?, Reason?>,
	DidApply: (self: any, Key: KeyLike, Id: string) -> Future<boolean?, Reason?>,
	History: (self: any, Key: KeyLike, Limit: number?) -> Future<{ HistoryEntry }?, Reason?>,
	PeekVersion: (self: any, Key: KeyLike, Version: string) -> Future<D?, Reason?>,
	Edit: (self: any, Key: KeyLike, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	Transfer: (self: any, From: KeyLike, To: KeyLike, Amount: number, Id: string?) -> Future<boolean, Reason?>,
	Bump: (self: any, Name: string, Field: string, Amount: number) -> Future<boolean, Reason?>,
	Total: (self: any, Name: string, Field: string) -> Future<number?, Reason?>,
	Reserve: (self: any, Key: KeyLike, Field: string, Amount: number, Id: string, Options: HoldOptions?) -> Future<boolean, Reason?>,
	Confirm: (self: any, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Release: (self: any, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Grant: (self: any, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Tx: (self: any, Id: string, Legs: { TxLeg }) -> Future<boolean, Reason?>,
	Resettle: (self: any, Key: KeyLike) -> Future<boolean, Reason?>,
	RecoverTransfers: (self: any, Key: KeyLike) -> Future<boolean, Reason?>,
	ClearDelivered: (self: any, Key: KeyLike) -> Future<boolean, Reason?>,
	Reset: (self: any, Key: KeyLike) -> Future<boolean, Reason?>,
	Erase: (self: any, Key: KeyLike) -> Future<boolean, Reason?>,
	Stale: (self: any) -> Observer<string>,
	Destroy: (self: any) -> (),
}

export type Config<D> = {
	read Name: string,
	read Reducer: (State: D, Op: Op) -> unknown,
	read Default: D,
	read Balance: string?,
	read Migrations: { Migration }?,
	read Keys: KeysMode?,
	read OnLoadFailed: ((Player: Player, Why: Reason) -> boolean)?,
}

return table.freeze({})
