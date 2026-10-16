--!strict
--!optimize 2

--[=[
	Shapes: the shapes the record's rule modules share: the limits, a store's build and setup, ops, requests and
	the server's state.

	A shape that an item or value module owns is imported from it. Events holds step's events and commands,
	Judging/Shapes the judged shapes and Judging/Run a write's working state.

	Return type: An empty table. The types are Limits, Migration, Build, Setup, Incarnation, MintedName, AskedName,
	OpForm, WaitingForm, WaitingOp, Op, SentOp, UpdateRequest, Request, Seen, ResumedWriter, KnownIncarnation,
	ShowableIncarnation, ShowableSource, Showable, UnservedShowables, CacheEntry, Outgoing, KeyKind, NumberAsk,
	NotTook, WriterState, ShownIncarnation, ShownTable, StoreState, LandedValue, StepOut and ServerState.
	Example usage:
		local Shapes = require("./Shapes")
		type Limits = Shapes.Limits
--]=]

local Balances = require("./Tx/Legs/Balances")
local Book = require("./Stored/Book")
local CutShapes = require("./Cuts/Shapes")
local Guards = require("./Judging/Guards")
local HashInputs = require("./Encoding/HashInputs")
local JudgingShapes = require("./Judging/Shapes")
local Names = require("./Encoding/Names")
local Pacing = require("./Writing/Pacing")
local Reasons = require("./Constants/Reasons")
local Recency = require("./Recency")
local Record = require("./Constants/Record")
local Seal = require("./Stored/Items/Seal")
local TxShapes = require("./Tx/Shapes")
local Value = require("./Stored/Value")
local Work = require("./Stored/Items/Work")

type Arithmetic = Balances.Arithmetic
type Declaration = Balances.Declaration
type Identity = Book.Identity
type Room<Item> = Book.Room<Item>
type Kept = Value.Kept
type Name = Names.Name
type OpName = Names.OpName
type GameOpName = Names.GameOpName
type StoreKey = Names.StoreKey
type KeyReference = Names.KeyReference
type Mark = Work.Mark
type Gate = Seal.Gate
type Paced = Pacing.Paced
type Recency = Recency.Recency
type Reason = Reasons.Reason
type Encoding = HashInputs.Encoding
type End = TxShapes.End
type TentForm = TxShapes.TentForm
type CommitForm = TxShapes.CommitForm
type CutForm = CutShapes.CutForm
type HeldEnd = TxShapes.HeldEnd
type Reducer = Guards.Reducer<unknown, unknown, unknown>
type Report = JudgingShapes.Report
type Note = JudgingShapes.Note

export type Limits = {
	read FreezeInputs: boolean,
	read ItemSize: <Item>(Room: Room<Item>, Item: Item, Epoch: number, WindowUnit: number) -> number,

	read Sigma: number,
	read Jump: number,
	read Ahead: number,
	read Hold: number,
	read Ceiling: number,
	read StampMax: number,

	read TimedRooms: { [string]: number },
	read UntimedRooms: { [string]: number },
	read WorkRooms: { [string]: number },
	read LossRooms: { [string]: number },
	read CutNamesKept: number,
	read MarkCap: number,
	read OwedCap: number,
	read FatesMax: number,
	read PostCap: number,
	read BookMax: number,
	read StateCap: number,
	read StateWarnBytes: number,

	read MintedWindow: number,
	read TimedWindows: { [string]: number },
	read UntimedWindows: { [string]: number },
	read CutWindow: number,
	read WindowUnit: number,
	read KeepNamed: number,
	read FoldSpan: number,
	read SlotSpans: number,
	read FoldSlotsMost: number,
	read SealAge: number,
	read RemoveSend: number,
	read OrphanAge: number,
	read PinEvictAge: number,
	read HoldSlack: number,

	read SequenceMax: number,
	read HorizonCacheKeys: number,
	read SentNamesKept: number,
	read ShownKeysMax: number,
	read UnservedShowableKeys: number,
	read ShownBitCount: number,
	read CounterKeyCount: number,

	read OpBound: number,
	read EraseBound: number,
	read ResetBound: number,
	read ShutdownSeconds: number,
	read ErrorsBeforeUnresolved: number,
	read RetryGapFirst: number,
	read RetryGapMost: number,
	read GapLeast: number,
	read GapMost: number,
	read QueueOpsMax: number,
	read QueueWait: number,
	read QueueRoomOps: number,
	read QueueRoomBytes: number,
	read NewTimedBytesMax: number,
	read SaveInterval: number,
	read IdleReadInterval: number,

	read SettleAge: number,
	read MaxAttempts: number,
	read RetryRounds: number,
	read OwedRecordsVerified: number,
	read GameOpMarksMost: number,
	read TouchLevels: number,
	read TouchStep: number,
	read HoldDrop: number,
	read FoldWindow: number,
}

export type Migration = {
	read Run: Guards.MigrationRun,
	read IsBreaking: boolean,
}

export type Build = {
	read KeyKind: KeyKind,
	read Migrations: { Migration },
	read MigrationCount: number,
	read BreakingIndex: number,
	read Reducer: Reducer,
	read Default: { [string]: unknown },
	read Declared: { [string]: boolean },
	read Balances: { [string]: Arithmetic },
	read BalanceOps: { [string]: Declaration },
	read MayReference: ((Reference: KeyReference) -> boolean)?,
}

export type Setup = {
	read Store: string,
	read Build: Build,
	read Limits: Limits,
	read Encoding: Encoding,
	read IsErasable: boolean,
	read CreatesOnFirstWrite: boolean,
	read PartBuild: Build,
}

export type Incarnation =
	{ read Kind: "Known", read Identity: Identity }
	| { read Kind: "Legacy" }
	| { read Kind: "Absent", read Fresh: Identity }
	| { read Kind: "Any" }

export type MintedName = { read Kind: "Minted", read WriterId: number, read Sequence: number }

export type AskedName =
	{ read Kind: "Game", read Text: string, read Stamp: number? }
	| { read Kind: "Drawn", read Server: number, read Counter: number, read Stamp: number }
	| MintedName
	| { read Kind: "Queued", read CallId: number }

export type OpForm =
	{ read Kind: "Minted", read Sequence: number }
	| { read Kind: "Timed", read Sequence: number, read Name: OpName }
	| { read Kind: "Untimed", read Sequence: number, read Name: GameOpName }
	| { read Kind: "Hopeful", read Sequence: number, read ViewCuts: number }
	| CutForm
	| TentForm
	| CommitForm

export type WaitingForm =
	{ read Kind: "Minted" }
	| { read Kind: "Timed", read Name: OpName, read Stamp: number }
	| { read Kind: "Untimed", read Name: GameOpName }
	| { read Kind: "Hopeful", read ViewCuts: number }

export type WaitingOp = {
	Form: WaitingForm,
	read OpKind: string,
	Terms: unknown,
	JoinedAt: number,
	MustExist: boolean,
	Size: number,
	CallId: number?,
	IsStep: boolean,
	GivesState: boolean?,
}

export type Op = {
	Form: OpForm,
	read OpKind: string,
	Terms: unknown,
	JoinedAt: number,
	MustExist: boolean,
	Size: number,
	Stamp: number?,
	Incarnation: Incarnation?,
	IsSent: boolean,
	CallId: number?,
	IsStep: boolean,
	GivesState: boolean?,
	ErrorsInARow: number,
	IsClean: boolean,
	IsHeard: boolean,
	IsAnswered: boolean,
	OwesOutcome: boolean,
	SentOrPassedAt: number?,
}

export type SentOp = {
	read Form: OpForm,
	read OpKind: string,
	read Terms: unknown,
	read Stamp: number,
	read Incarnation: Incarnation,
	read IsClean: boolean,
}

export type UpdateRequest = {
	read Kind: "Update",
	read WriterId: number?,
	read Acknowledged: number,
	read MustExist: boolean,
	read Ops: { SentOp },
	read Ends: { End },
}

export type Request =
	UpdateRequest
	| { read Kind: "Fresh" }
	| { read Kind: "Probe", read Name: Name, read Stamp: number }
	| { read Kind: "ProveGone" }
	| CutShapes.SealStampRequest

export type Seen = { Kind: "Known", Identity: Identity } | { Kind: "Legacy" } | { Kind: "Absent" }

export type ResumedWriter = {
	WriterId: number,
	NextSequence: number,
}

export type KnownIncarnation = { read Kind: "Known", read Identity: Identity? }

export type ShowableIncarnation = KnownIncarnation | { read Kind: "Unknown" }

export type ShowableSource =
	{ read Kind: "Book", read Incarnation: KnownIncarnation }
	| { read Kind: "Copy", read Incarnation: ShowableIncarnation }

export type Showable = {
	Writes: number,
	State: { [unknown]: unknown },
	From: ShowableSource,
}

export type UnservedShowables = {
	States: { [string]: Showable },
	Order: Recency,
}

export type CacheEntry = {
	Horizon: number?,
	Seen: Seen?,
	Resumed: ResumedWriter?,
	IsSizeWarned: boolean?,
	TidiedAt: number?,
	Work: { Mark }?,
	Gate: Gate?,
	Showable: Showable?,
	IsBehind: boolean?,
}

export type Outgoing = {
	RequestId: number,
	Request: Request,
}

export type KeyKind = Record.KeyKind

export type NumberAsk = { read Kind: "Life" } | { read Kind: "Shared" } | { read Kind: "Writer", read Key: StoreKey }

export type NotTook = "TurnedAway" | "Unknown"

export type WriterState = {
	Key: StoreKey,
	read Text: string,
	Kind: KeyKind,
	WriterId: number,
	NextSequence: number,
	NextWriterId: number?,
	Queue: { Op },
	Waiting: { WaitingOp },
	Acknowledged: number,
	Out: Outgoing?,
	Final: Outgoing?,
	ErrorsInARow: number,
	RetryAt: number?,
	FinalWaitsRetry: boolean,
	IdleSince: number?,
	QueuedHopefulBytes: number,
	QueuedHopeful: number,
	FirstSequence: number,
	NotTook: { [number]: NotTook },
	MintedByCall: { [number]: MintedName },
	HelpId: number?,
	Paced: Paced?,
	TidyOwed: boolean,
}

export type ShownIncarnation =
	{ read Kind: "Known", read Identity: Identity }
	| { read Kind: "None" }
	| { read Kind: "Unknown" }

export type ShownTable = {
	Order: Recency,
	Keys: { [string]: StoreKey },
	Counts: { [string]: number },
	Incarnations: { [string]: ShownIncarnation },
	LastShown: { [string]: number },
	Bits: buffer,
}

export type StoreState = {
	Setup: Setup,
	Writers: { [string]: WriterState },
	IsUnreadableWarned: boolean?,
}

export type LandedValue = {
	read Key: StoreKey,
	read Written: Kept,
	read Bytes: number?,
}

export type StepOut =
	{ read Kind: "Answered", read CallId: number, read Reason: Reason }
	| { read Kind: "Heard", read CallId: number, read Reason: Reason?, read Report: Report, read Note: Note }
	| { read Kind: "Late", read CallId: number, read Reason: Reason?, read Report: Report }

export type ServerState = {
	JobId: string,
	Encoding: Encoding,
	Limits: Limits?,
	ServerNumber: number?,
	WriterNumber: number?,
	NumbersAsked: { [number]: NumberAsk },
	Counter: number,
	RequestCounter: number,
	HelperCounter: number,
	Caches: { [string]: CacheEntry },
	CacheOrder: Recency,
	Unserved: UnservedShowables,
	Shown: ShownTable,
	SentNames: { [string]: string },
	SentOrder: Recency,
	Stores: { [string]: StoreState },
	Rides: { [string]: { HeldEnd } },
	WorkSeen: { [string]: StoreKey },
	SealsSeen: { [string]: CutShapes.SeenSeal },
	Landed: { LandedValue },
	StepOut: { StepOut },
}

return {}
