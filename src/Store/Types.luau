--!strict
--!optimize 2

--[=[
	Types: The store declarations.

	These are private to this folder. This file holds declarations, and never logic.
	The impl type is the whole surface that the halves of the store call each other through.
	A game cannot name any of it.
	Swept is the store as the sweep sees it, five plain functions carrying no self. The sweep holds
	those and never a store, because a sweeper that held stores would put Store, Fields and Sweeper in
	a ring that setmetatable cannot close. It is the shape the scheduler and the hook already take.

	Return type: An empty table. The types are Allow, Swept, Stranded, SweeperImpl, Sweeper, LoadedEntry, LoadPhase, Meter, Fields, StoreImpl and Store.
	Example usage:
		local Types = require("./Types")
		type Store = Types.Store<D>
--]=]

local Future = require("../Util/Future")
local Observer = require("../Util/Observer")
local DataStoreWrapper = require("../Util/DataStoreWrapper")
local Shapes = require("../Core/Shapes")
local Api = require("../Core/Api")
local Reasons = require("../Core/Reasons")
local LogTypes = require("../Record/Types")
local LiveTypes = require("../Session/Types")

type Future<T...> = Future.Future<T...>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Op = Shapes.Op
type Record = Shapes.Record<any>
type Reducer<S> = Shapes.Reducer<S>
type Migration = Shapes.Migration
type KeyLike = Shapes.KeyLike
type KeysMode = Shapes.KeysMode
type HistoryEntry = Shapes.HistoryEntry
type Reason = Reasons.Reason
type Config<D> = Api.Config<D>
type TxLeg = Api.TxLeg
type HoldOptions = Api.HoldOptions
type Session<S> = LiveTypes.Session<S>

export type Allow = (Record) -> boolean

export type Swept = {
	read Mark: (Key: string) -> string,
	read Affords: (Kind: Enum.DataStoreRequestType, Floor: number) -> boolean,
	read TxAffords: (Kind: Enum.DataStoreRequestType, Floor: number) -> boolean,
	read Repair: (Key: string) -> (boolean, boolean),
	read ReapMarkers: () -> number,
}

export type Stranded = { Store: Swept, Key: string, Tries: number }

export type SweeperImpl = {
	__index: SweeperImpl,

	New: () -> Sweeper,
	Adopt: (self: Sweeper, Held: Swept) -> (),
	Retime: (self: Sweeper) -> (),
	Add: (self: Sweeper, Held: Swept, Key: string) -> (),
	Drop: (self: Sweeper, Mark: string) -> (),
	Forget: (self: Sweeper, Held: Swept) -> (),
	Reap: (self: Sweeper, Mine: number?) -> (),
	Pass: (self: Sweeper) -> (),
	Stop: (self: Sweeper) -> (),
}

export type Sweeper = setmetatable<{
	Entries: { [string]: Stranded },
	Stores: { Swept },
	Count: number,
	Passes: number,
	Resume: number,
	Epoch: number,
	Ticker: thread,
}, SweeperImpl>

export type LoadedEntry<D> = {
	Active: Session<D>,
	Ticks: number,
	Ticker: thread,
}

export type LoadPhase = "Loading" | "Leaving"

export type Meter = {
	Skipped: number,
	At: number,
	Records: number,
	Markers: number,
	Swollen: number,
	Said: number,
}

export type Fields<D> = {
	Options: Config<D>,
	Reducer: Reducer<D>,
	Wrapper: DataStoreWrapper,
	TxWrapper: DataStoreWrapper,
	Initial: D,
	Migrations: { Migration },
	Handles: { [string]: boolean },
	Books: LogTypes.Log?,
	Shaped: LogTypes.Shape<D>?,
	Keys: KeysMode,
	Loaded: { [number]: LoadedEntry<D> },
	Waiters: { [number]: { thread } },
	Loads: { [number]: LoadPhase },
	Saving: { [Future<boolean, Reason?>]: boolean },
	Node: string,
	Sweep: Sweeper,
	Sweeping: Swept?,
	Staleness: Observer.Subject<string>,
	Meter: Meter,
	Resume: number?,
	Closed: boolean,
}

export type StoreImpl<D> = {
	__index: StoreImpl<D>,

	Mark: (self: Store<D>, Key: string) -> string,
	KeyFor: (self: Store<D>, Value: any) -> string?,
	KeyIssue: (self: Store<D>) -> string,
	Live: (self: Store<D>, What: string) -> (),
	Resolve: (self: Store<D>, Key: KeyLike, What: string) -> string,
	ExpectPlayers: (self: Store<D>, What: string) -> (),
	ExpectBalance: (self: Store<D>, What: string) -> (),
	Affords: (self: Store<D>, Kind: Enum.DataStoreRequestType, Floor: number) -> boolean,
	TxAffords: (self: Store<D>, Kind: Enum.DataStoreRequestType, Floor: number) -> boolean,
	Swept: (self: Store<D>) -> Swept,
	Records: (self: Store<D>) -> LogTypes.Log,
	Format: (self: Store<D>) -> LogTypes.Shape<D>,
	Fold: (self: Store<D>, Record: Record) -> D,
	ReadRecord: (self: Store<D>, Key: string) -> Record,

	Watch: (self: Store<D>, Key: string, Record: Record) -> (),
	WatchHeld: (self: Store<D>, Key: string, State: any) -> (),
	Stale: (self: Store<D>) -> Observer.Observer<string>,
	Went: (self: Store<D>, Key: string) -> (),
	Append: (self: Store<D>, Key: string, Op: Op, Guard: Allow?) -> Record,
	Maintain: (self: Store<D>, Key: string, Record: Record) -> Record,
	Applies: (self: Store<D>, Op: Op, Record: Record) -> (boolean, boolean),
	Swollen: (self: Store<D>, Op: Op, Record: Record) -> boolean,
	Written: (self: Store<D>, Key: string, Op: Op, What: string, Guard: Allow?, Denied: Reason?) -> (boolean, Reason?),
	Swelling: (self: Store<D>, Key: string, Record: Record) -> (),
	Starved: (self: Store<D>, Pool: Enum.DataStoreRequestType) -> (),

	Freed: (self: Store<D>, Key: string, State: any) -> boolean,
	HeldOn: (self: Store<D>, Key: string) -> (boolean, any),
	HandOver: (self: Store<D>, Key: string) -> (number, number),
	HandBooked: (self: Store<D>, Key: string) -> (),
	TallyName: (self: Store<D>, Name: any, Field: any, What: string) -> string,
	Repair: (self: Store<D>, Key: string) -> (boolean, boolean),
	ReapMarkers: (self: Store<D>) -> number,
	Buried: (self: Store<D>, Key: string, Replaced: Record) -> (),

	Wake: (self: Store<D>, UserId: number, Active: Session<D>?) -> (),
	PickUp: (self: Store<D>, Active: Session<D>, UserId: number) -> (),
	Handled: (self: Store<D>, Player: Player, Why: Reason) -> boolean,
	Autosave: (self: Store<D>, UserId: number) -> (),
	Save: (self: Store<D>, Active: Session<D>) -> Future<boolean, Reason?>,
	Handed: (self: Store<D>, Key: string, Rid: string, Held: Shapes.Booked) -> boolean,

	Load: (self: Store<D>, Player: Player) -> (),
	Unload: (self: Store<D>, Player: Player) -> (),
	Get: (self: Store<D>, Player: Player) -> Session<D>?,
	Expect: (self: Store<D>, Player: Player) -> Session<D>,
	IsLoaded: (self: Store<D>, Player: Player) -> boolean,
	WaitForLoaded: (self: Store<D>, Player: Player) -> Session<D>?,
	Read: (self: Store<D>, Player: Player) -> D?,
	Peek: (self: Store<D>, Key: KeyLike) -> Future<D?, Reason?>,
	Inspect: (self: Store<D>, Key: KeyLike) -> Future<Record?, Reason?>,
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
	Destroy: (self: Store<D>) -> (),
}

export type Store<D> = setmetatable<Fields<D>, StoreImpl<D>>

return table.freeze({})
