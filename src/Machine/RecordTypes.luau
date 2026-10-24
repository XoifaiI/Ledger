--!strict
--!optimize 2

--[=[
	RecordTypes: the public shapes of a stored record, as Inspect, Losses and Pending answer them. They are written
	out, not made by Frozen, keeping their lists read-only.

	Return type: An empty table. The types are exported.
	Example usage:
		local RecordTypes = require("./RecordTypes")
		type Record = RecordTypes.Record<{ Gold: number }>
--]=]

local Book = require("../Record/Stored/Book")
local Losses = require("../Record/Stored/Items/Losses")
local Names = require("../Record/Encoding/Names")
local Operators = require("../Features/Tx/Work/Operators")
local Post = require("../Record/Stored/Post")
local Seal = require("../Record/Stored/Items/Seal")
local Timed = require("../Record/Stored/Items/Timed")
local TypeFunctions = require("../TypeFunctions")
local Work = require("../Record/Stored/Items/Work")

type Frozen<S> = TypeFunctions.Frozen<S>
type PathStep = Post.PathStep
type StoreKey = Names.StoreKey

type Identity = Frozen<Book.Identity>

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

return {}
