--!strict
--!optimize 2

--[=[
    Types: the shared data shapes, kept here so the modules can reference each other
    without a require cycle.

    an op is one immutable edit carrying its own id for dedupe. a record is the stored
    snapshot, every op since, and a bounded set of ids already folded into the snapshot
    so dedupe survives compaction.

    Return type: type definitions only, returns {}
    Example usage:
        local Types = require("./Types")
        type Op = Types.Op
        type Reducer<S> = Types.Reducer<S>
--]=]

local Future = require("./Util/Future")
local Observer = require("./Util/Observer")
local DataStoreWrapper = require("./Util/DataStoreWrapper")

type Future<T...> = Future.Future<T...>
type Observer<T> = Observer.Observer<T>
type Subject<T> = Observer.Subject<T>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper

export type Op = {
	Id: string,
	Kind: string,
	[any]: any,
}

export type Record<S> = {
	Snapshot: S?,
	Ops: { Op },
	Seen: { string },
	Version: number?,
	Floor: number?,
	Envelope: number?,
}

export type HistoryEntry = {
	Version: string,
	At: number,
	Deleted: boolean,
}

export type TxLeg = {
	UserId: number,
	Kind: string,
	Fields: { [any]: any }?,
}

export type Reducer<S> = (State: S, Op: Op) -> S?

export type Migration = ((State: any) -> any) | { Apply: (State: any) -> any, Compatible: boolean? }

export type SessionImpl<S> = {
	__index: SessionImpl<S>,
	Get: (self: Session<S>) -> S,
	Apply: (self: Session<S>, Kind: string, Fields: { [any]: any }?) -> boolean,
	Commit: (self: Session<S>, Kind: string, Fields: { [any]: any }?) -> Future<boolean>,
	CommitOp: (self: Session<S>, Op: Op) -> Future<boolean>,
	Flush: (self: Session<S>) -> Future<()>,
	Compact: (self: Session<S>) -> Future<()>,
	Release: (self: Session<S>) -> Future<()>,
	Observe: (self: Session<S>) -> Observer<S>,
}

export type Session<S> = setmetatable<{
	Wrapper: DataStoreWrapper,
	Key: string,
	Reducer: Reducer<S>,
	Migrations: { Migration },
	TxStore: DataStoreWrapper?,
	Initial: S,
	State: S,
	Applied: { [string]: boolean },
	Pending: { Op },
	LogSize: number,
	LogBytes: number,
	Changed: Subject<S>,
	Released: boolean,
}, SessionImpl<S>>

export type Store<D> = {
	Configure: (self: Store<D>, Options: { Name: string, Reducer: Reducer<D>, Default: D, Balance: string?, Migrations: { Migration }? }) -> (),
	Load: (self: Store<D>, Player: Player) -> (),
	Unload: (self: Store<D>, Player: Player) -> (),
	CloseAll: (self: Store<D>) -> (),
	Get: (self: Store<D>, Player: Player) -> Session<D>?,
	Expect: (self: Store<D>, Player: Player) -> Session<D>,
	IsLoaded: (self: Store<D>, Player: Player) -> boolean,
	WaitForLoaded: (self: Store<D>, Player: Player) -> Session<D>?,
	Read: (self: Store<D>, Player: Player) -> D?,
	Peek: (self: Store<D>, UserId: number) -> Future<D>,
	History: (self: Store<D>, UserId: number, Limit: number?) -> Future<{ HistoryEntry }>,
	PeekVersion: (self: Store<D>, UserId: number, Version: string) -> Future<D>,
	Edit: (self: Store<D>, UserId: number, Kind: string, Fields: { [any]: any }?) -> Future<()>,
	Transfer: (self: Store<D>, FromUserId: number, ToUserId: number, Amount: number) -> Future<boolean>,
	Tx: (self: Store<D>, Legs: { TxLeg }) -> Future<boolean>,
	RecoverTransfers: (self: Store<D>, UserId: number) -> Future<()>,
	ClearDelivered: (self: Store<D>, UserId: number) -> Future<()>,
	Reset: (self: Store<D>, UserId: number) -> Future<()>,
	Erase: (self: Store<D>, UserId: number) -> Future<()>,
}

export type Config = {
	Name: string,
	Reducer: Reducer<any>,
	Default: any,
	Balance: string?,
	Migrations: { Migration }?,
}

export type Runtime = {
	Options: Config,
	Reducer: Reducer<any>,
	Wrapper: DataStoreWrapper,
	TxWrapper: DataStoreWrapper,
	Initial: any,
	Migrations: { Migration },
}

export type DataStoreImpl = {
	__index: DataStoreImpl,
	Configure: (self: DataStore, Options: Config) -> (),
	Load: (self: DataStore, Player: Player) -> (),
	Unload: (self: DataStore, Player: Player) -> (),
	CloseAll: (self: DataStore) -> (),
	Get: (self: DataStore, Player: Player) -> Session<any>?,
	Expect: (self: DataStore, Player: Player) -> Session<any>,
	IsLoaded: (self: DataStore, Player: Player) -> boolean,
	WaitForLoaded: (self: DataStore, Player: Player) -> Session<any>?,
	Read: (self: DataStore, Player: Player) -> any,
	Peek: (self: DataStore, UserId: number) -> Future<any>,
	History: (self: DataStore, UserId: number, Limit: number?) -> Future<{ HistoryEntry }>,
	PeekVersion: (self: DataStore, UserId: number, Version: string) -> Future<any>,
	Edit: (self: DataStore, UserId: number, Kind: string, Fields: { [any]: any }?) -> Future<()>,
	Transfer: (self: DataStore, FromUserId: number, ToUserId: number, Amount: number) -> Future<boolean>,
	Tx: (self: DataStore, Legs: { TxLeg }) -> Future<boolean>,
	RecoverTransfers: (self: DataStore, UserId: number) -> Future<()>,
	ClearDelivered: (self: DataStore, UserId: number) -> Future<()>,
	Reset: (self: DataStore, UserId: number) -> Future<()>,
	Erase: (self: DataStore, UserId: number) -> Future<()>,
}

export type DataStore = setmetatable<{ Live: Runtime? }, DataStoreImpl>

return {}
