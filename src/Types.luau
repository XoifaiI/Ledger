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
	Bytes: number?,
	Ops: { Op },
	Seen: { string },
	Version: number?,
	Floor: number?,
	Envelope: number?,
	Erased: number?
}

export type HistoryEntry = {
	Version: string,
	At: number,
	Deleted: boolean
}

export type KeysMode = "Player" | "String"

export type KeyLike = number | string

export type Reason =
	"Refused" | "Busy" | "Spent" | "Unresolved" | "Closed" | "Backlog" | "Full" | "Invalid" | "Behind" | "Held"

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

export type Reducer<S> = (State: S, Op: Op) -> S?

export type Migration = ((State: any) -> any) | { Apply: (State: any) -> any, Compatible: boolean? }
export type LogOutcome = { Before: Record<any>, After: Record<any>, Changed: boolean }

export type LogResolution = { Record: Record<any>, Counts: { [string]: number } }

export type LogVerdict = { Commit: boolean, Gen: string?, Since: number? }

export type LogPrepared = "Prepared" | "Settled" | "Busy" | "Rejected" | "Spent"

export type LogFated = "Owned" | "Dead"

export type ShapeImpl<S> = {
	__index: ShapeImpl<S>,

	Floor: (self: Shape<S>) -> number,
	Rehydrate: (self: Shape<S>, Record: Record<any>) -> S,
	Fold: (self: Shape<S>, Record: Record<any>) -> S,
	Certain: (self: Shape<S>, Record: Record<any>, Id: string) -> (boolean, boolean)
}

export type Shape<S> = setmetatable<{
	read Reducer: Reducer<S>,
	read Initial: S,
	read Migrations: { Migration },
	read Blobbed: boolean
}, ShapeImpl<S>>

export type LogImpl = {
	__index: LogImpl,

	Update: (self: LogHandle, Key: string, Apply: (Record<any>) -> Record<any>?) -> LogOutcome,
	Read: (self: LogHandle, Key: string) -> Record<any>,
	ReadVersion: (self: LogHandle, Key: string, Version: string) -> Record<any>,
	Append: (self: LogHandle, Key: string, Ops: { Op }, Guard: ((Record<any>) -> boolean)?) -> Record<any>,
	AppendUnlessPending: (self: LogHandle, Key: string, Ops: { Op }) -> Record<any>,
	Entomb: (self: LogHandle, Key: string, At: number, Bury: ((Record<any>) -> Record<any>)?) -> Record<any>,
	Prepare: (self: LogHandle, Key: string, Op: Op, Format: Shape<any>) -> LogPrepared,
	Resolve: (self: LogHandle, Key: string, Verdicts: { [string]: LogVerdict }) -> LogResolution,
	Compact: (self: LogHandle, Key: string, Format: Shape<any>) -> Record<any>,
	Trim: (self: LogHandle, Key: string, Format: Shape<any>, Record: Record<any>) -> Record<any>
}

export type LogHandle = setmetatable<{
	read Wrapper: DataStoreWrapper,
	read Known: number?
}, LogImpl>

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

export type Admitted<S> =
	{ read Outcome: "Refused", read Why: Reason }
	| { read Outcome: "Rejected" }
	| { read Outcome: "Accepted", read Next: S, read Bytes: number?, read Also: S? }

export type SessionImpl<S> = {
	__index: SessionImpl<S>,

	ApplyPending: (self: Session<S>, State: S, Applied: { [string]: boolean }) -> S,
	Push: (self: Session<S>) -> (Record<any>?, boolean?),
	CheckPurity: (self: Session<S>, Stored: Record<any>, Folded: S) -> (),
	Rebuild: (self: Session<S>, Stored: Record<any>, Mark: string?) -> (S, boolean),
	Notify: (self: Session<S>) -> (),
	SettlePending: (self: Session<S>, Stored: Record<any>) -> Record<any>,
	Settled: (self: Session<S>, Stored: Record<any>) -> Record<any>,
	Admit: (self: Session<S>, Op: Op, OpBytes: number, Durable: boolean?) -> Admitted<S>,

	Get: (self: Session<S>) -> S,
	Apply: (self: Session<S>, Kind: string, Fields: { [any]: any }?) -> (boolean, Reason?),
	Commit: (self: Session<S>, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	CommitOp: (self: Session<S>, Op: Op) -> Future<boolean, Reason?>,
	Flush: (self: Session<S>) -> Future<boolean, Reason?>,
	Compact: (self: Session<S>) -> Future<boolean, Reason?>,
	Release: (self: Session<S>) -> Future<boolean, Reason?>,
	Observe: (self: Session<S>) -> Observer<S>,
	DidApply: (self: Session<S>, Id: string) -> boolean
}

export type Session<S> = setmetatable<{
	Log: LogHandle,
	Shape: Shape<S>,
	Key: string,
	TxStore: DataStoreWrapper?,
	State: S,
	Landed: S?,
	Fence: number?,
	Parked: number,
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

type LoadedEntry = {
	Active: Session<any>,
	Ticks: number,
	Ticker: thread
}

type LoadPhase = "Loading" | "Leaving"

type Meter = {
	Skipped: number,
	At: number,
	Records: number,
	Markers: number,
	Swollen: number,
	Said: number
}

type StoreFields = {
	Options: Config<any>,
	Reducer: Reducer<any>,
	Wrapper: DataStoreWrapper,
	TxWrapper: DataStoreWrapper,
	Initial: any,
	Migrations: { Migration },
	Books: LogHandle?,
	Shaped: Shape<any>?,
	Keys: KeysMode,
	Loaded: { [number]: LoadedEntry },
	Waiters: { [number]: { thread } },
	Loads: { [number]: LoadPhase },
	Saving: { [Future<boolean, Reason?>]: boolean },
	Meter: Meter,
	ReapAt: number,
	Closed: boolean
}

export type DataStoreImpl = {
	__index: DataStoreImpl,

	Mark: (self: DataStore, Key: string) -> string,
	KeyFor: (self: DataStore, Value: any) -> string?,
	KeyIssue: (self: DataStore) -> string,
	Live: (self: DataStore, What: string) -> (),
	Resolve: (self: DataStore, Key: KeyLike, What: string) -> string,
	ExpectPlayers: (self: DataStore, What: string) -> (),
	ExpectBalance: (self: DataStore, What: string) -> (),
	Records: (self: DataStore) -> LogHandle,
	Format: (self: DataStore) -> Shape<any>,
	Fold: (self: DataStore, Record: Record<any>) -> any,
	ReadRecord: (self: DataStore, Key: string) -> Record<any>,
	Watch: (self: DataStore, Key: string, Record: Record<any>) -> (),
	WatchHeld: (self: DataStore, Key: string, State: any) -> (),
	Freed: (self: DataStore, Key: string, State: any) -> boolean,
	Repair: (self: DataStore, Key: string) -> (boolean, boolean),
	ReapMarkers: (self: DataStore) -> number,
	Wake: (self: DataStore, UserId: number, Active: Session<any>?) -> (),
	Append: (self: DataStore, Key: string, Op: Op, Guard: ((Record<any>) -> boolean)?) -> Record<any>,
	Maintain: (self: DataStore, Key: string, Record: Record<any>) -> Record<any>,
	Applies: (self: DataStore, Op: Op, Record: Record<any>) -> boolean,
	Written: (self: DataStore, Key: string, Op: Op, What: string, Guard: ((Record<any>) -> boolean)?, Denied: Reason?) -> (boolean, Reason?),
	Starved: (self: DataStore, Pool: Enum.DataStoreRequestType) -> (),
	Swelling: (self: DataStore, Key: string, Record: Record<any>) -> (),
	Autosave: (self: DataStore, UserId: number) -> (),
	Save: (self: DataStore, Active: Session<any>) -> Future<boolean, Reason?>,
	Buried: (self: DataStore, Key: string, Replaced: Record<any>) -> (),
	Handled: (self: DataStore, Player: Player, Why: Reason) -> boolean,

	Load: (self: DataStore, Player: Player) -> (),
	Unload: (self: DataStore, Player: Player) -> (),
	Get: (self: DataStore, Player: Player) -> Session<any>?,
	Expect: (self: DataStore, Player: Player) -> Session<any>,
	IsLoaded: (self: DataStore, Player: Player) -> boolean,
	WaitForLoaded: (self: DataStore, Player: Player) -> Session<any>?,
	Read: (self: DataStore, Player: Player) -> any,
	Peek: (self: DataStore, Key: KeyLike) -> Future<any?, Reason?>,
	Inspect: (self: DataStore, Key: KeyLike) -> Future<Record<any>?, Reason?>,
	DidApply: (self: DataStore, Key: KeyLike, Id: string) -> Future<boolean?, Reason?>,
	History: (self: DataStore, Key: KeyLike, Limit: number?) -> Future<{ HistoryEntry }?, Reason?>,
	PeekVersion: (self: DataStore, Key: KeyLike, Version: string) -> Future<any?, Reason?>,
	Edit: (self: DataStore, Key: KeyLike, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	Transfer: (self: DataStore, From: KeyLike, To: KeyLike, Amount: number, Id: string?) -> Future<boolean, Reason?>,
	Bump: (self: DataStore, Name: string, Field: string, Amount: number) -> Future<boolean, Reason?>,
	Total: (self: DataStore, Name: string, Field: string) -> Future<number?, Reason?>,
	Reserve: (self: DataStore, Key: KeyLike, Field: string, Amount: number, Id: string, Options: HoldOptions?) -> Future<boolean, Reason?>,
	Confirm: (self: DataStore, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Release: (self: DataStore, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Grant: (self: DataStore, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Handed: (self: DataStore, Key: string, Rid: string, Held: { [any]: any }) -> boolean,
	Tx: (self: DataStore, Id: string, Legs: { TxLeg }) -> Future<boolean, Reason?>,
	Resettle: (self: DataStore, Key: KeyLike) -> Future<boolean, Reason?>,
	RecoverTransfers: (self: DataStore, Key: KeyLike) -> Future<boolean, Reason?>,
	ClearDelivered: (self: DataStore, Key: KeyLike) -> Future<boolean, Reason?>,
	Reset: (self: DataStore, Key: KeyLike) -> Future<boolean, Reason?>,
	Erase: (self: DataStore, Key: KeyLike) -> Future<boolean, Reason?>,
	Destroy: (self: DataStore) -> ()
}

export type DataStore = setmetatable<StoreFields, DataStoreImpl>

return table.freeze({})
