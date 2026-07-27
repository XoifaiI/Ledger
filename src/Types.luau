--!strict
--!optimize 2

-- the shared data shapes, kept here so the modules can reference each other without a require cycle

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
	[any]: any
}

export type Record<S> = {
	Snapshot: S?,
	Ops: { Op },
	Seen: { string },
	Version: number?,
	Floor: number?,
	Envelope: number?
}

export type HistoryEntry = {
	Version: string,
	At: number,
	Deleted: boolean
}

export type KeysMode = "Player" | "String"

export type KeyLike = number | string

export type Reason =
	"Refused" | "Busy" | "Spent" | "Unresolved" | "Closed" | "Backlog" | "Full" | "Invalid"

export type TxLeg = {
	Store: Store<any>?,
	UserId: number?,
	Key: string?,
	Kind: string,
	Fields: { [any]: any }?
}

export type Reducer<S> = (State: S, Op: Op) -> S?

export type LogOutcome = { Before: Record<any>, After: Record<any>, Changed: boolean }

export type LogResolution = { Record: Record<any>, Counts: { [string]: number } }

export type Shape<S> = {
	Reducer: Reducer<S>,
	Initial: S,
	Migrations: { Migration },

	Floor: (self: Shape<S>) -> number,
	Rehydrate: (self: Shape<S>, Record: Record<any>) -> S,
	Fold: (self: Shape<S>, Record: Record<any>) -> S,
	Accepted: (self: Shape<S>, Record: Record<any>, Id: string) -> boolean
}

export type LogHandle = {
	Wrapper: DataStoreWrapper,

	Update: (self: LogHandle, Key: string, Apply: (Record<any>) -> Record<any>?) -> LogOutcome,
	Read: (self: LogHandle, Key: string) -> Record<any>,
	ReadVersion: (self: LogHandle, Key: string, Version: string) -> Record<any>,
	Append: (self: LogHandle, Key: string, Ops: { Op }, Guard: ((Record<any>) -> boolean)?) -> Record<any>,
	AppendUnlessPending: (self: LogHandle, Key: string, Ops: { Op }) -> Record<any>,
	Prepare: (self: LogHandle, Key: string, Op: Op, Format: Shape<any>) -> string,
	Resolve: (self: LogHandle, Key: string, Verdicts: { [string]: boolean }) -> LogResolution,
	Compact: (self: LogHandle, Key: string, Format: Shape<any>) -> Record<any>
}

export type Migration = ((State: any) -> any) | { Apply: (State: any) -> any, Compatible: boolean? }

export type SessionImpl<S> = {
	__index: SessionImpl<S>,

	ApplyPending: (self: Session<S>, State: S, Applied: { [string]: boolean }) -> S,
	Push: (self: Session<S>) -> Record<any>?,
	CheckPurity: (self: Session<S>, Stored: Record<any>, Folded: S) -> (),
	Rebuild: (self: Session<S>, Stored: Record<any>, Mark: string?) -> (S, boolean),
	Notify: (self: Session<S>) -> (),
	SettlePending: (self: Session<S>, Stored: Record<any>) -> Record<any>,
	Settled: (self: Session<S>, Stored: Record<any>) -> Record<any>,
	Admit: (self: Session<S>, Op: Op, OpBytes: number) -> { Why: Reason?, Next: S?, Bytes: number? },

	Get: (self: Session<S>) -> S,
	Apply: (self: Session<S>, Kind: string, Fields: { [any]: any }?) -> (boolean, Reason?),
	Commit: (self: Session<S>, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	CommitOp: (self: Session<S>, Op: Op) -> Future<boolean, Reason?>,
	Flush: (self: Session<S>) -> Future<boolean>,
	Compact: (self: Session<S>) -> Future<boolean>,
	Release: (self: Session<S>) -> Future<boolean>,
	Observe: (self: Session<S>) -> Observer<S>
}

export type Session<S> = setmetatable<{
	Log: LogHandle,
	Shape: Shape<S>,
	Key: string,
	TxStore: DataStoreWrapper?,
	State: S,
	Applied: { [string]: boolean },
	Pending: { Op },
	LogSize: number,
	LogBytes: number,
	StateBytes: number,
	Changed: Subject<S>,
	Released: boolean
}, SessionImpl<S>>

export type Store<D> = {
	Load: (self: Store<D>, Player: Player) -> (),
	Unload: (self: Store<D>, Player: Player) -> (),
	Get: (self: Store<D>, Player: Player) -> Session<D>?,
	Expect: (self: Store<D>, Player: Player) -> Session<D>,
	IsLoaded: (self: Store<D>, Player: Player) -> boolean,
	WaitForLoaded: (self: Store<D>, Player: Player) -> Session<D>?,
	Read: (self: Store<D>, Player: Player) -> D?,
	Peek: (self: Store<D>, Key: KeyLike) -> Future<D>,
	History: (self: Store<D>, Key: KeyLike, Limit: number?) -> Future<{ HistoryEntry }>,
	PeekVersion: (self: Store<D>, Key: KeyLike, Version: string) -> Future<D>,
	Edit: (self: Store<D>, Key: KeyLike, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	Transfer: (self: Store<D>, From: KeyLike, To: KeyLike, Amount: number, Id: string?) -> Future<boolean, Reason?>,
	Tx: (self: Store<D>, Id: string, Legs: { TxLeg }) -> Future<boolean, Reason?>,
	RecoverTransfers: (self: Store<D>, Key: KeyLike) -> Future<()>,
	ClearDelivered: (self: Store<D>, Key: KeyLike) -> Future<()>,
	Reset: (self: Store<D>, Key: KeyLike) -> Future<boolean, Reason?>,
	Erase: (self: Store<D>, Key: KeyLike) -> Future<()>
}

export type Config = {
	Name: string,
	Reducer: Reducer<any>,
	Default: any,
	Balance: string?,
	Migrations: { Migration }?,
	Keys: KeysMode?
}

export type LoadedEntry = {
	Active: Session<any>,
	Ticker: thread
}

export type StoreFields = {
	Options: Config,
	Reducer: Reducer<any>,
	Wrapper: DataStoreWrapper,
	TxWrapper: DataStoreWrapper,
	Initial: any,
	Migrations: { Migration },
	Keys: KeysMode,
	Loaded: { [number]: LoadedEntry },
	Waiters: { [number]: { thread } },
	Leaving: { [number]: boolean },
	Loading: { [number]: boolean },
	Saving: { [Future<boolean>]: boolean }
}

export type DataStoreImpl = {
	__index: DataStoreImpl,

	Mark: (self: DataStore, Key: string) -> string,
	KeyFor: (self: DataStore, Value: any) -> string?,
	KeyIssue: (self: DataStore) -> string,
	Resolve: (self: DataStore, Key: KeyLike, What: string) -> string,
	ExpectPlayers: (self: DataStore, What: string) -> (),
	ExpectBalance: (self: DataStore, What: string) -> (),
	Fold: (self: DataStore, Record: Record<any>) -> any,
	ReadRecord: (self: DataStore, Key: string) -> Record<any>,
	Watch: (self: DataStore, Key: string, Record: Record<any>) -> (),
	Resettle: (self: DataStore, Key: string) -> boolean,
	Wake: (self: DataStore, UserId: number, Active: Session<any>?) -> (),
	Append: (self: DataStore, Key: string, Op: Op, Guard: ((Record<any>) -> boolean)?) -> Record<any>,
	Maintain: (self: DataStore, Key: string, Record: Record<any>) -> Record<any>,
	Written: (self: DataStore, Key: string, Op: Op, What: string, Guard: ((Record<any>) -> boolean)?) -> (boolean, Reason?),
	Autosave: (self: DataStore, UserId: number) -> (),
	Save: (self: DataStore, Active: Session<any>) -> Future<boolean>,

	Load: (self: DataStore, Player: Player) -> (),
	Unload: (self: DataStore, Player: Player) -> (),
	Get: (self: DataStore, Player: Player) -> Session<any>?,
	Expect: (self: DataStore, Player: Player) -> Session<any>,
	IsLoaded: (self: DataStore, Player: Player) -> boolean,
	WaitForLoaded: (self: DataStore, Player: Player) -> Session<any>?,
	Read: (self: DataStore, Player: Player) -> any,
	Peek: (self: DataStore, Key: KeyLike) -> Future<any>,
	History: (self: DataStore, Key: KeyLike, Limit: number?) -> Future<{ HistoryEntry }>,
	PeekVersion: (self: DataStore, Key: KeyLike, Version: string) -> Future<any>,
	Edit: (self: DataStore, Key: KeyLike, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	Transfer: (self: DataStore, From: KeyLike, To: KeyLike, Amount: number, Id: string?) -> Future<boolean, Reason?>,
	Tx: (self: DataStore, Id: string, Legs: { TxLeg }) -> Future<boolean, Reason?>,
	RecoverTransfers: (self: DataStore, Key: KeyLike) -> Future<()>,
	ClearDelivered: (self: DataStore, Key: KeyLike) -> Future<()>,
	Reset: (self: DataStore, Key: KeyLike) -> Future<boolean, Reason?>,
	Erase: (self: DataStore, Key: KeyLike) -> Future<()>
}

export type DataStore = setmetatable<StoreFields, DataStoreImpl>

return {}
