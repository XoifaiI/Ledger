--!strict
--!optimize 2

--[=[
	Types: the public types. Typed views hold each op to the game's op map; annotating an op with
	Ledger.OpOf<Ops, "AddCoins"> names the field in errors. Ledger's own shapes are written out, not made by Frozen,
	keeping their lists read-only. A bare D outside Default and parameters breaks refining an inferred D.
	QuantityDeclaration.Closed guards this build only; older builds can Open.

	Return type: An empty table. The types are exported.
	Example usage:
		local Types = require("./Types")
		type Store = Types.TypedStore<{ Gold: number }, { AddGold: { Amount: number } }>
--]=]

local Amounts = require("./Encoding/Amounts")
local Book = require("./Stored/Book")
local Fates = require("./Stored/Items/Fates")
local Future = require("./Util/Future")
local Guards = require("./Judging/Guards")
local Hot = require("./Constants/Hot")
local HotShapes = require("./Hot/Shapes")
local Losses = require("./Stored/Items/Losses")
local Names = require("./Encoding/Names")
local Observer = require("./Util/Observer")
local Operators = require("./Tx/Work/Operators")
local Post = require("./Stored/Post")
local Reasons = require("./Constants/Reasons")
local Seal = require("./Stored/Items/Seal")
local ShellSetup = require("./Shell/Setup")
local Timed = require("./Stored/Items/Timed")
local TypeFunctions = require("./TypeFunctions")
local Work = require("./Stored/Items/Work")
local WritingAnswers = require("./Writing/Answers")

type Emitted = WritingAnswers.Emitted
type MigrationRun = Guards.MigrationRun
type Mode = Hot.Mode
type Ops = ShellSetup.Ops
type PathStep = Post.PathStep
type Serials = HotShapes.Serials
type StoreKey = Names.StoreKey

export type Reason = Reasons.Reason
export type KeyLike = Player | number | string
export type KeysMode = ShellSetup.KeysMode
export type OpMap = { [string]: { [string]: unknown } }
export type Frozen<S> = TypeFunctions.Frozen<S>
export type Future<T...> = Future.Future<T...>
export type Observer<T> = Observer.Observer<T>
export type Connection = Observer.Connection
export type Identity = Frozen<Book.Identity>
export type LoadFailedHandler = ShellSetup.LoadFailedHandler
export type ShortReason = Fates.ShortReason
export type Amount = Frozen<Amounts.SignedAmount | Amounts.UnsignedAmount>

export type Arithmetic<T = any> = {
	read Zero: T,
	read Add: (Left: T, Right: T) -> T,
	read Subtract: (Left: T, Right: T) -> T,
	read Compare: (Left: T, Right: T) -> number,
	read IsValid: (Value: unknown) -> boolean,
	read Encode: (Value: T) -> string,
	read Decode: (Text: string) -> T?,
	read Max: T?,
}

export type HoldHandle = Frozen<HotShapes.HoldHandle>
export type QuantityTotal = Frozen<HotShapes.QuantityTotal>
export type Took = Frozen<HotShapes.Took>

type ReadArray<Item> = { read [number]: Item }
type ReadMap = { read [unknown]: unknown }
type FieldAmount = Frozen<Losses.FieldAmount>
type CoreName = Frozen<Names.Name>
type KeyReference = Frozen<Names.KeyReference>

type LossEvent = {
	read Cause: Timed.CutKind,
	read Name: CoreName,
	read Stamp: number,
	read Fields: ReadArray<FieldAmount>,
	read Fingerprint: number?,
}

type LossReturn = {
	read Cause: Losses.ReturnCause,
	read Name: CoreName,
	read Stamp: number,
	read OtherKey: KeyReference,
	read Escrow: FieldAmount?,
	read Fingerprint: number?,
}

type LossSlot = {
	read Period: number,
	read Count: number,
	read Sums: ReadArray<FieldAmount>,
}

export type LossRecords = {
	read Events: ReadArray<LossEvent>,
	read Returns: ReadArray<LossReturn>,
	read Slots: ReadArray<LossSlot>,
}

export type Closed = {
	read Removed: ReadArray<number>,
	read Left: ReadArray<number>,
	read Missing: ReadArray<number>,
}

type PendingItem = Frozen<Operators.PendingMark> | {
	read Kind: "Pinned",
	read Name: CoreName,
	read Stamp: number,
	read Age: number,
	read Attempt: number,
	read IsDecided: boolean,
	read Legs: ReadArray<Frozen<StoreKey>>,
}

export type PendingItems = ReadArray<PendingItem>

type BookMark = Frozen<Work.EscrowMark> | {
	read Kind: "Exclusive",
	read IsClean: boolean,
	read Opening: Frozen<Work.MarkOpening>,
	read Decider: KeyReference,
	read Slot: ReadArray<PathStep>?,
} | {
	read Kind: "Pinned",
	read IsClean: boolean,
	read Opening: Frozen<Work.MarkOpening>,
	read OtherLegs: ReadArray<KeyReference>,
	read DeciderValue: number?,
}

type BookTimed = Frozen<Timed.NamedEntry> | {
	read Kind: "Writer",
	read WriterId: number,
	read Highest: number,
	read Newest: number,
	read Fates: ReadArray<Frozen<Timed.WriterFate>>,
}

type RecordBook = {
	read Format: number,
	read Level: number,
	read Floor: number,
	read Writes: number,
	read Cuts: number,
	read Identity: Identity?,
	read Gate: Frozen<Seal.Gate>?,
	read Epoch: number,
	read Horizon: number,
	read CutHorizon: number,
	read Timed: ReadArray<BookTimed>,
	read CutNames: ReadArray<Frozen<Timed.CutName>>,
	read Untimed: ReadArray<Frozen<Timed.NamedEntry>>,
	read Work: ReadArray<BookMark>,
	read Losses: { read Events: ReadArray<LossEvent>, read Returns: ReadArray<LossReturn> },
	read Slots: ReadArray<LossSlot>,
}

type PostEntry =
	{ read Kind: "Set", read Path: ReadArray<PathStep>, read Value: unknown }
	| { read Kind: "Removed", read Path: ReadArray<PathStep> }

export type Record<D = unknown> = {
	read Kind: "Kept",
	read State: Frozen<D> & ReadMap,
	read Book: RecordBook,
	read Post: ReadArray<PostEntry>?,
	read Given: ReadMap?,
}

export type Name = string | OpId

export type Terms<O = any> = TypeFunctions.OpUnion<O, {}>
export type Op<O = any> = Terms<O>
export type OpOf<O, K> = TypeFunctions.OpOf<O, K, {}>
export type Overloads<O, Shape> = TypeFunctions.Overloads<Op<O>, Shape>
export type Reducer<S, O = any> = Guards.Reducer<S, Terms<O>>

type ConfigReducer<D, O> = Guards.Reducer<D, Terms<O>, D & {}>

export type ResultSchema<D> = ShellSetup.ResultSchema<D>

export type Migration = {
	read Run: MigrationRun,
	read IsBreaking: boolean?,
	read Fields: { string }?,
}

export type BalanceKindLimits<T = any> = {
	read Kind: string,
	read Min: TypeFunctions.NoInfer<T>?,
	read Max: TypeFunctions.NoInfer<T>?,
}

export type BalanceField<T = any> = {
	read Credit: (string | { string | BalanceKindLimits<T> })?,
	read Debit: (string | { string | BalanceKindLimits<T> })?,
	read Min: TypeFunctions.NoInfer<T>?,
	read Max: TypeFunctions.NoInfer<T>?,
	read Arithmetic: Arithmetic<T>?,
}

export type Windows = {
	[string]: {
		read Timed: number?,
		read Untimed: number?,
	},
}

export type TotalDeclaration = { read Shards: number? }

export type QuantityDeclaration = {
	read Parts: number,
	read Mode: Mode,
	read Stock: number?,
	read Serials: Serials?,
	read Proceeds: { string }?,
	read Closed: boolean?,
}

export type TypedConfig<D, O> = {
	read Name: string,
	read Keys: KeysMode,
	read Default: D,
	read Reducer: ConfigReducer<D, O>?,
	read Schema: ResultSchema<D>?,
	read Balances: { [string]: BalanceField }?,
	read Migrations: { Migration }?,
	read MustExist: boolean,
	read Erasable: boolean,
	read LegLimit: number?,
	read OnLoadFailed: LoadFailedHandler?,
	read Kick: boolean?,
	read KickMessage: string?,
	read SaveInterval: number?,
	read IdleReadInterval: number?,
	read HoldMax: number?,
	read OrphanAge: number?,
	read Windows: Windows?,
	read CutWindow: number?,
	read Totals: { [string]: TotalDeclaration }?,
	read Quantities: { [string]: QuantityDeclaration }?,
	read Mock: unknown?,
}

export type Config<D> = TypedConfig<D, any>

export type OpId = {
	read Name: { read Kind: string },
}

export type Applied = {
	read Name: { read Kind: string },
	read CallId: number,
	read Key: Frozen<StoreKey>,
}

export type Info<D = unknown> = {
	read State: Frozen<D>?,
	read Identity: Identity?,
	read Key: InfoKey?,
	read ShortReason: ShortReason?,
	read Name: Name?,
	read Outcome: Future<boolean, Reason?>?,
}

export type DidApplyInfo = Frozen<{
	IsQueued: true?,
}>

export type Cut = {
	read Name: Name,
	read Losses: LossRecords?,
}

export type EditOptions = {
	read MustExist: boolean?,
	read Id: Name?,
	read IdAt: number?,
}

export type CommitOptions = {
	read Id: Name?,
	read IdAt: number?,
}

export type BumpOptions = {
	read Id: string?,
	read IdAt: number?,
}

export type PeekOptions = {
	read Fresh: true,
}

export type DidApplyOptions = {
	read IdAt: number?,
	read Probe: boolean?,
}

export type ResetOptions<D> = {
	read Id: OpId?,
	read IdAt: number?,
	read State: Frozen<D>?,
}

export type EraseOptions = {
	read Id: OpId?,
	read IdAt: number?,
}

export type TxOptions = {
	read Id: string?,
	read IdAt: number?,
}

export type TakeOptions = {
	read Price: (number | { read [string]: unknown })?,
	read Id: string?,
	read IdAt: number?,
	read Legs: { TakeLeg }?,
}

type AnyStore = {
	read Leg: (Store: any, ...any) -> ...any,
	read Quantity: (Store: any, Name: string) -> ...any,
}

export type KeyOfStore = {
	read Store: AnyStore,
	read Key: KeyLike,
}

export type GatherOptions = {
	read Kind: string?,
	read Id: string?,
	read IdAt: number?,
}

export type WithdrawOptions = {
	read Kind: string?,
}

export type ConfirmOptions = {
	read Price: (number | { read [string]: unknown })?,
	read Legs: { TakeLeg }?,
}

export type DepositOptions = {
	read From: KeyOfStore?,
	read Field: string?,
	read Kind: string?,
	read Part: number?,
}

export type TxLeg = {
	read Store: Store<any>,
	read Key: KeyLike,
	read Op: { read Kind: string },
	read MustExist: boolean?,
}

export type LegOptions = {
	read MustExist: boolean?,
	read Slot: { string | number }?,
}

export type Leg<S> = {
	read Store: S,
	read Key: KeyLike,
	read Op: { read Kind: string },
	read MustExist: boolean?,
	read Slot: { string | number }?,
}

export type TakeLeg = Leg<AnyStore>

export type FateOp<O = any> = TypeFunctions.OpenAsAny<Frozen<Terms<O>>>

export type Fate<O = any> = {
	read Applied: Applied,
	read Fate: Emitted,
	read Op: FateOp<O>,
}

export type InfoKey = Frozen<{
	Store: string,
	Key: string | number,
}>

export type SessionCommon<D, O = any> = {
	Get: (self: SessionCommon<D, O>) -> Frozen<D>,
	Observe: (self: SessionCommon<D, O>) -> Observer<Frozen<D>>,
	ObserveFates: (self: SessionCommon<D, O>) -> Observer<Fate<O>>,
	DidApply: (
		self: SessionCommon<D, O>,
		Name: Applied | Name,
		Options: DidApplyOptions?
	) -> (boolean?, Reason?, DidApplyInfo?),
	Flush: (self: SessionCommon<D, O>) -> (boolean, Reason?, Info?),
	Refresh: (self: SessionCommon<D, O>) -> (boolean, Reason?),
	Release: (self: SessionCommon<D, O>) -> (boolean, Reason?, Info?),
}

export type TypedSession<D, O> = SessionCommon<D, O> & {
	Apply: (self: TypedSession<D, O>, Op: Op<O>) -> (boolean, Applied | Reason, Info?),
	Commit: (self: TypedSession<D, O>, Op: Op<O>, Options: CommitOptions?) -> (boolean, Frozen<D> | Reason, Info<D>?),
}

export type Session<D> = SessionCommon<D> & {
	Apply: (self: Session<D>, Op: Op) -> (boolean, Applied | Reason, Info?),
	Commit: (self: Session<D>, Op: Op, Options: CommitOptions?) -> (boolean, Frozen<D> | Reason, Info<D>?),
}

export type Quantity = {
	Total: (self: Quantity, MaxAge: number?) -> (QuantityTotal?, Reason?),
	Take: (self: Quantity, Count: number, Options: TakeOptions?) -> (boolean, Took | Reason, Info?),
	Gather: (
		self: Quantity,
		Count: number,
		To: KeyOfStore,
		Field: string,
		Options: GatherOptions?
	) -> (boolean, Reason?, Info?),
	Hold: (self: Quantity, Count: number, Duration: number) -> (boolean, HoldHandle | Reason, Info?),
	Open: (self: Quantity) -> (boolean, Reason?, Info?),
	Close: (self: Quantity) -> (boolean, Closed | Reason, Info?),
	Confirm: (self: Quantity, Hold: HoldHandle, Options: ConfirmOptions?) -> (boolean, (number | Reason)?, Info?),
	Release: (self: Quantity, Hold: HoldHandle) -> (boolean, Reason?, Info?),
	Deposit: (self: Quantity, Count: number, Options: DepositOptions?) -> (boolean, Reason?, Info?),
	Withdraw: (
		self: Quantity,
		Count: unknown,
		Part: number,
		To: number | KeyOfStore,
		Field: string,
		Options: WithdrawOptions?
	) -> (boolean, Reason?, Info?),
}

export type KeyPages<K = string | number> = {
	Next: (self: KeyPages<K>) -> ({ K }?, Reason?),
}

export type StoreCommon<D> = {
	Peek: (
		self: StoreCommon<D>,
		Key: KeyLike,
		Freshness: (number | PeekOptions)?
	) -> (Frozen<D>?, Reason?, Info<D>?),
	Inspect: (self: StoreCommon<D>, Key: KeyLike) -> (Record<D>?, Reason?),
	DidApply: (self: StoreCommon<D>, Key: KeyLike, Name: Name, Options: DidApplyOptions?) -> (boolean?, Reason?),
	Reset: (self: StoreCommon<D>, Key: KeyLike, Options: ResetOptions<D>?) -> (boolean, Cut | Reason, Info?),
	Erase: (self: StoreCommon<D>, Key: KeyLike, Options: EraseOptions?) -> (boolean, Cut | Reason, Info?),
	Losses: (self: StoreCommon<D>, Key: KeyLike) -> (LossRecords?, Reason?),
	Pending: (self: StoreCommon<D>, Key: KeyLike) -> (PendingItems?, Reason?),
	Resettle: (self: StoreCommon<D>, Key: KeyLike) -> (boolean, Reason?, Info?),
	Follow: (self: StoreCommon<D>, Key: KeyLike) -> Observer<Frozen<D> | "Behind">,
	Stale: (self: StoreCommon<D>) -> Observer<string | number>,
	Bump: (self: StoreCommon<D>, Total: string, Amount: number, Options: BumpOptions?) -> (boolean, Reason?, Info?),
	Total: (self: StoreCommon<D>, Name: string, MaxAge: number?) -> (number?, Reason?),
	Quantity: (self: StoreCommon<D>, Name: string) -> Quantity,
	Keys: (self: StoreCommon<D>) -> KeyPages<string | number>,
	Unload: (self: StoreCommon<D>, Player: Player) -> (),
	IsLoaded: (self: StoreCommon<D>, Player: Player) -> boolean,
	Read: (self: StoreCommon<D>, Player: Player) -> Frozen<D>?,
	Destroy: (self: StoreCommon<D>) -> (),
}

export type TypedStore<D, O> = StoreCommon<D> & {
	Edit: (self: TypedStore<D, O>, Key: KeyLike, Op: Op<O>, Options: EditOptions?) -> (boolean, Reason?, Info<D>?),
	Load: (self: TypedStore<D, O>, Player: Player) -> (TypedSession<D, O>?, Reason?),
	Get: (self: TypedStore<D, O>, Player: Player) -> TypedSession<D, O>?,
	Expect: (self: TypedStore<D, O>, Player: Player) -> TypedSession<D, O>,
	WaitForLoaded: (self: TypedStore<D, O>, Player: Player) -> TypedSession<D, O>?,
	Leg: (self: TypedStore<D, O>, Key: KeyLike, Op: Terms<O>, Options: LegOptions?) -> Leg<any>,
}

export type Store<D> = StoreCommon<D> & {
	Edit: (self: Store<D>, Key: KeyLike, Op: Op, Options: EditOptions?) -> (boolean, Reason?, Info<D>?),
	Load: (self: Store<D>, Player: Player) -> (Session<D>?, Reason?),
	Get: (self: Store<D>, Player: Player) -> Session<D>?,
	Expect: (self: Store<D>, Player: Player) -> Session<D>,
	WaitForLoaded: (self: Store<D>, Player: Player) -> Session<D>?,
	Leg: (self: Store<D>, Key: KeyLike, Op: Terms<any>, Options: LegOptions?) -> Leg<any>,
}

type SameMethods =
	TypeFunctions.SameKeys<keyof<Store<any>>, keyof<TypedStore<any, any>>>
	| TypeFunctions.SameKeys<keyof<Session<any>>, keyof<TypedSession<any, any>>>

return {}
