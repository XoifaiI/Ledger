--!strict
--!optimize 2

--[=[
	Notes: a run's note, cancel and land (record sheet 9, S.9).

	A note carries each op's and end's report, the gate, its copy of P and whether it shows a key; a seal shows none.
	A stop leaves each end Undecided. Only shard and part landings carry written bytes. A probe's unheld name is
	forgotten under either horizon (cuts 3.1).

	Return type: A plain table of the functions, Cancelled and NothingShown, and the types Output, Shown, Ending.
	Example usage:
		return Notes.CancelWith(Request, Report, Shown, Closure, {})
--]=]

local Book = require("../Stored/Book")
local Json = require("../Encoding/Json")
local JudgingShapes = require("./Shapes")
local Lookup = require("../Stored/Lookup")
local Names = require("../Encoding/Names")
local Record = require("../Constants/Record")
local Rooms = require("../Stored/Rooms")
local Seal = require("../Stored/Items/Seal")
local Shapes = require("../Shapes")
local Value = require("../Stored/Value")
local Work = require("../Stored/Items/Work")

type Identity = Book.Identity
type Kept = Value.Kept
type Value = Value.Value
type Mark = Work.Mark
type Name = Names.Name
type Gate = Seal.Gate
type Seal = Seal.Seal
type Setup = Shapes.Setup
type Closure = JudgingShapes.Closure
type Request = Shapes.Request
type UpdateRequest = Shapes.UpdateRequest
type Report = JudgingShapes.Report
type NoteWarning = JudgingShapes.NoteWarning
type Note = JudgingShapes.Note
type Book = Book.Book

export type Output = { read Kind: "Write", read Value: { [string]: unknown } } | { read Kind: "Cancel" }

export type Shown = {
	read Writes: number,
	read Cuts: number,
	read Horizon: number,
	read CutHorizon: number,
	read Identity: Identity?,
	read ShowsKey: boolean,
	read State: unknown,
	read Work: { Mark },
	read Gate: Gate?,
}

export type Ending = {
	read Reports: { Report },
	read ProbeReport: Report?,
	read Warnings: { NoteWarning },
	read EndReports: { Report },
}

local GameKind = Record.KeyKind.Game

local Cancelled: Output = table.freeze({ Kind = "Cancel" :: "Cancel" })
local NotAppliedReport: Report = table.freeze({ Kind = "Undecided" :: "Undecided" })

local NoWork: { Mark } = {}
table.freeze(NoWork)

local NothingShown: Shown = table.freeze({
	Writes = 0,
	Cuts = 0,
	Horizon = 0,
	CutHorizon = 0,
	Identity = nil,
	ShowsKey = false,
	State = nil,
	Work = NoWork,
	Gate = nil,
})

local function ShownOf(Read: Kept): Shown
	return {
		Writes = Read.Book.Writes,
		Cuts = Read.Book.Cuts,
		Horizon = Read.Book.Horizon,
		CutHorizon = Read.Book.CutHorizon,
		Identity = Read.Book.Identity,
		ShowsKey = true,
		State = Read.State,
		Work = table.clone(Read.Book.Work),
		Gate = Read.Book.Gate,
	}
end

local function NoteWritten(Shown: Shown, Carried: Closure, Ending: Ending, Written: Value?, Bytes: number?): Note
	return {
		Reports = Ending.Reports,
		Writes = Shown.Writes,
		Cuts = Shown.Cuts,
		Horizon = Shown.Horizon,
		CutHorizon = Shown.CutHorizon,
		Identity = Shown.Identity,
		ShowsKey = Shown.ShowsKey,
		Closure = Carried,
		State = Shown.State,
		WrittenValue = Written,
		WrittenBytes = Bytes,
		ProbeReport = Ending.ProbeReport,
		Warnings = Ending.Warnings,
		EndReports = Ending.EndReports,
		Work = Shown.Work,
		Gate = Shown.Gate,
	}
end

local function BuildNote(Shown: Shown, Carried: Closure, Ending: Ending, Written: Value?): Note
	return NoteWritten(Shown, Carried, Ending, Written, nil)
end

local function CancelWith(
	Request: Request,
	Report: Report,
	Shown: Shown,
	Closure: Closure,
	Warnings: { NoteWarning }
): (Output, Note)
	if Request.Kind == "Update" then
		local Reported: Ending = {
			Reports = table.create(#Request.Ops, Report),
			ProbeReport = nil,
			Warnings = Warnings,
			EndReports = table.create(#Request.Ends, Report),
		}
		return Cancelled, BuildNote(Shown, Closure, Reported, nil)
	end
	local Probed: Ending = { Reports = {}, ProbeReport = Report, Warnings = Warnings, EndReports = {} }
	return Cancelled, BuildNote(Shown, Closure, Probed, nil)
end

local function CancelAtOp(
	Request: UpdateRequest,
	Report: Report,
	Shown: Shown,
	Closure: Closure,
	Warnings: { NoteWarning }
): (Output, Note)
	local Reported: Ending = {
		Reports = table.create(#Request.Ops, Report),
		ProbeReport = nil,
		Warnings = Warnings,
		EndReports = table.create(#Request.Ends, NotAppliedReport),
	}
	return Cancelled, BuildNote(Shown, Closure, Reported, nil)
end

local function CancelEach(Reports: { Report }, EndReports: { Report }, Shown: Shown, Closure: Closure): (Output, Note)
	local Reported: Ending = { Reports = Reports, ProbeReport = nil, Warnings = {}, EndReports = EndReports }
	return Cancelled, BuildNote(Shown, Closure, Reported, nil)
end

local function Land(Key: Kept, Setup: Setup, Closure: Closure, Ending: Ending): (Output, Note)
	local Working = Key.Book
	Working.Writes += 1
	Working.Epoch = Rooms.EpochOf(Working) or 0
	Rooms.SortRooms(Working)
	local Marked: Closure = { Wrote = true, Ran = Closure.Ran }
	local Encoded = Value.EncodeValue(Key, Setup.Build, Setup.Limits.WindowUnit)
	local Output: Output = { Kind = "Write", Value = Encoded }
	local Bytes = if Setup.Build.KeyKind == GameKind then nil else Json.Size(Encoded)
	return Output, NoteWritten(ShownOf(Key), Marked, Ending, Key, Bytes)
end

local function LandSeal(Sealed: Seal, Setup: Setup, Closure: Closure, Ending: Ending): (Output, Note)
	local Written: Value = { Kind = "Sealed", Seal = Sealed }
	local Marked: Closure = { Wrote = true, Ran = Closure.Ran }
	local Output: Output = { Kind = "Write", Value = Value.EncodeValue(Written, Setup.Build, Setup.Limits.WindowUnit) }
	return Output, BuildNote(NothingShown, Marked, Ending, Written)
end

local function ProbeReportOf(Working: Book, Name: Name, Stamp: number): Report
	local Held = Lookup.HeldOfAsked(Working, Name)
	if Held ~= nil then
		return Held
	end
	if Stamp <= Working.Horizon or Stamp <= Working.CutHorizon then
		return { Kind = "Forgotten" }
	end
	return { Kind = "Landed" }
end

return {
	Cancelled = Cancelled,
	NothingShown = NothingShown,
	ShownOf = ShownOf,
	BuildNote = BuildNote,
	CancelWith = CancelWith,
	CancelAtOp = CancelAtOp,
	CancelEach = CancelEach,
	Land = Land,
	LandSeal = LandSeal,
	ProbeReportOf = ProbeReportOf,
}
