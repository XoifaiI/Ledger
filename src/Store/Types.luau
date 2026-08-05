--!strict
--!optimize 2

--[=[
	Types: The store declarations.
	
	These are private to this folder. This file holds declarations, and never logic.
	The impl type is the whole surface that the halves of the store call each other through.
	A game cannot name any of it.
	
	Return type: An empty table. The types are Allow, LoadedEntry, LoadPhase, Meter, Fields, StoreImpl and Store.
	Example usage:
		local Types = require("./Types")
		type Store = Types.Store
--]=]

local Future = require("../Util/Future")
local DataStoreWrapper = require("../Util/DataStoreWrapper")
local Contract = require("../Contract/Op")
local Public = require("../Contract/Public")
local Reasons = require("../Contract/Reason")
local LogTypes = require("../Record/Types")
local LiveTypes = require("../Live/Types")

type Future<T...> = Future.Future<T...>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Op = Contract.Op
type Record = Contract.Record<any>
type Reducer<S> = Contract.Reducer<S>
type Migration = Contract.Migration
type KeyLike = Contract.KeyLike
type KeysMode = Contract.KeysMode
type HistoryEntry = Contract.HistoryEntry
type Reason = Reasons.Reason
type Config<D> = Public.Config<D>
type TxLeg = Public.TxLeg
type HoldOptions = Public.HoldOptions
type Session<S> = LiveTypes.Session<S>

export type Allow = (Record) -> boolean

export type LoadedEntry = {
	Active: Session<any>,
	Ticks: number,
	Ticker: thread
}

export type LoadPhase = "Loading" | "Leaving"

export type Meter = {
	Skipped: number,
	At: number,
	Records: number,
	Markers: number,
	Swollen: number,
	Said: number
}

export type Fields = {
	Options: Config<any>,
	Reducer: Reducer<any>,
	Wrapper: DataStoreWrapper,
	TxWrapper: DataStoreWrapper,
	Initial: any,
	Migrations: { Migration },
	Books: LogTypes.Log?,
	Shaped: LogTypes.Shape<any>?,
	Keys: KeysMode,
	Loaded: { [number]: LoadedEntry },
	Waiters: { [number]: { thread } },
	Loads: { [number]: LoadPhase },
	Saving: { [Future<boolean, Reason?>]: boolean },
	Meter: Meter,
	ReapAt: string,
	Closed: boolean
}

export type StoreImpl = {
	__index: StoreImpl,

	Mark: (self: Store, Key: string) -> string,
	KeyFor: (self: Store, Value: any) -> string?,
	KeyIssue: (self: Store) -> string,
	Live: (self: Store, What: string) -> (),
	Resolve: (self: Store, Key: KeyLike, What: string) -> string,
	ExpectPlayers: (self: Store, What: string) -> (),
	ExpectBalance: (self: Store, What: string) -> (),
	Records: (self: Store) -> LogTypes.Log,
	Format: (self: Store) -> LogTypes.Shape<any>,
	Fold: (self: Store, Record: Record) -> any,
	ReadRecord: (self: Store, Key: string) -> Record,

	Watch: (self: Store, Key: string, Record: Record) -> (),
	WatchHeld: (self: Store, Key: string, State: any) -> (),
	Append: (self: Store, Key: string, Op: Op, Guard: Allow?) -> Record,
	Maintain: (self: Store, Key: string, Record: Record) -> Record,
	Applies: (self: Store, Op: Op, Record: Record) -> boolean,
	Swollen: (self: Store, Op: Op, Record: Record) -> boolean,
	Written: (self: Store, Key: string, Op: Op, What: string, Guard: Allow?, Denied: Reason?) -> (boolean, Reason?),
	Swelling: (self: Store, Key: string, Record: Record) -> (),
	Starved: (self: Store, Pool: Enum.DataStoreRequestType) -> (),

	Freed: (self: Store, Key: string, State: any) -> boolean,
	Repair: (self: Store, Key: string) -> (boolean, boolean),
	ReapMarkers: (self: Store) -> number,
	Buried: (self: Store, Key: string, Replaced: Record) -> (),

	Wake: (self: Store, UserId: number, Active: Session<any>?) -> (),
	Handled: (self: Store, Player: Player, Why: Reason) -> boolean,
	Autosave: (self: Store, UserId: number) -> (),
	Save: (self: Store, Active: Session<any>) -> Future<boolean, Reason?>,
	Handed: (self: Store, Key: string, Rid: string, Held: { [any]: any }) -> boolean,

	Load: (self: Store, Player: Player) -> (),
	Unload: (self: Store, Player: Player) -> (),
	Get: (self: Store, Player: Player) -> Session<any>?,
	Expect: (self: Store, Player: Player) -> Session<any>,
	IsLoaded: (self: Store, Player: Player) -> boolean,
	WaitForLoaded: (self: Store, Player: Player) -> Session<any>?,
	Read: (self: Store, Player: Player) -> any,
	Peek: (self: Store, Key: KeyLike) -> Future<any?, Reason?>,
	Inspect: (self: Store, Key: KeyLike) -> Future<Record?, Reason?>,
	DidApply: (self: Store, Key: KeyLike, Id: string) -> Future<boolean?, Reason?>,
	History: (self: Store, Key: KeyLike, Limit: number?) -> Future<{ HistoryEntry }?, Reason?>,
	PeekVersion: (self: Store, Key: KeyLike, Version: string) -> Future<any?, Reason?>,
	Edit: (self: Store, Key: KeyLike, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	Transfer: (self: Store, From: KeyLike, To: KeyLike, Amount: number, Id: string?) -> Future<boolean, Reason?>,
	Bump: (self: Store, Name: string, Field: string, Amount: number) -> Future<boolean, Reason?>,
	Total: (self: Store, Name: string, Field: string) -> Future<number?, Reason?>,
	Reserve: (self: Store, Key: KeyLike, Field: string, Amount: number, Id: string, Options: HoldOptions?) -> Future<boolean, Reason?>,
	Confirm: (self: Store, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Release: (self: Store, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Grant: (self: Store, Key: KeyLike, Id: string) -> Future<boolean, Reason?>,
	Tx: (self: Store, Id: string, Legs: { TxLeg }) -> Future<boolean, Reason?>,
	Resettle: (self: Store, Key: KeyLike) -> Future<boolean, Reason?>,
	RecoverTransfers: (self: Store, Key: KeyLike) -> Future<boolean, Reason?>,
	ClearDelivered: (self: Store, Key: KeyLike) -> Future<boolean, Reason?>,
	Reset: (self: Store, Key: KeyLike) -> Future<boolean, Reason?>,
	Erase: (self: Store, Key: KeyLike) -> Future<boolean, Reason?>,
	Destroy: (self: Store) -> ()
}

export type Store = setmetatable<Fields, StoreImpl>

return table.freeze({})
