--!strict
--!optimize 2

--[=[
	Shapes: what judging a request gives back: the report each op gets, the note the request leaves with what its
	closure wrote and ran, a reducer's verdict and an op's judged fate.

	A report a protocol owns is imported from that protocol's Shapes. A write's working state is in Judging/Run.
	Unreadable's Amounts cause lies beside the value, not in it.

	Return type: An empty table. The types are Closure, Shortage, UnreadableCause, EndWorkReport, Report, NoteWarning,
	Note, Verdict and Judged.
	Example usage:
		local JudgingShapes = require("./Judging/Shapes")
		type Report = JudgingShapes.Report
--]=]

local Book = require("../Stored/Book")
local CutShapes = require("../Cuts/Shapes")
local Fates = require("../Stored/Items/Fates")
local Names = require("../Encoding/Names")
local Seal = require("../Stored/Items/Seal")
local TxShapes = require("../Tx/Shapes")
local Value = require("../Stored/Value")
local Work = require("../Stored/Items/Work")

type Identity = Book.Identity
type Value = Value.Value
type Fate = Fates.Fate
type PartReason = Fates.PartReason
type Name = Names.Name
type Mark = Work.Mark
type Gate = Seal.Gate
type Seal = Seal.Seal

export type Closure = {
	Wrote: boolean,
	Ran: { [number]: boolean },
}

export type Shortage = { read Items: number, read Bytes: number }

export type UnreadableCause = Value.UnreadableCause | "Balance" | "Amounts"

export type EndWorkReport =
	{ read Kind: "NoRoom", read Marks: { Mark }, read Short: Shortage? }
	| { read Kind: "Overdue", read Marks: { Mark } }
	| { read Kind: "Blocked", read Marks: { Mark } }

export type Report =
	EndWorkReport
	| { read Kind: "Fated", read Fate: Fate, read State: unknown }
	| { read Kind: "Cut" }
	| { read Kind: "Spent" }
	| { read Kind: "Forgotten" }
	| { read Kind: "Landed" }
	| { read Kind: "Behind" }
	| { read Kind: "Ahead" }
	| {
		read Kind: "Missing",
		read Identity: Identity?,
		read Seal: Seal?,
		read IsLeftOver: boolean,
		read IsLegacy: boolean,
	}
	| { read Kind: "Undecided" }
	| { read Kind: "Unreadable", read Cause: UnreadableCause }
	| { read Kind: "Worn" }
	| { read Kind: "Owed", read Marks: { Mark } }
	| { read Kind: "Gated", read Gate: Gate }
	| { read Kind: "GatedBy", read Gate: Gate, read Marks: { Mark } }
	| { read Kind: "Marks", read Marks: { Mark } }
	| { read Kind: "Wait", read At: number }
	| { read Kind: "Gone" }
	| { read Kind: "Sealed", read Seal: Seal }
	| { read Kind: "Invalid" }
	| CutShapes.CutReport
	| TxShapes.TxReport

export type NoteWarning =
	{ read Kind: "AlsoCut", read Name: Name }
	| { read Kind: "CreatedAfterErase" }
	| { read Kind: "UnnamedBalance", read Field: string }
	| { read Kind: "WrittenBeforeErasable" }

export type Note = {
	read Reports: { Report },
	read Writes: number,
	read Cuts: number,
	read Horizon: number,
	read CutHorizon: number,
	read Identity: Identity?,
	read ShowsKey: boolean,
	read Closure: Closure,
	read State: unknown,
	read WrittenValue: Value?,
	read WrittenBytes: number?,
	read ProbeReport: Report?,
	read Warnings: { NoteWarning },
	read EndReports: { Report },
	read Work: { Mark },
	read Gate: Gate?,
}

export type Verdict =
	{ read Kind: "Took", read State: { [unknown]: unknown } }
	| { read Kind: "TookWith", read State: { [unknown]: unknown }, read Value: number }
	| { read Kind: "RefusedFor", read Reason: PartReason }
	| { read Kind: "NoState" }
	| { read Kind: "Unstorable" }
	| { read Kind: "Refused" }
	| { read Kind: "Full" }
	| { read Kind: "Unreadable" }
	| { read Kind: "Invalid" }
	| { read Kind: "InvalidBalance" }

export type Judged = Fate | { read Kind: "Unreadable" } | { read Kind: "Invalid" }

return {}
