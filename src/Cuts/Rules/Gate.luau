--!strict
--!optimize 2

--[=[
	Gate: cut rules 6 to 8 (cuts sheet 4.6 to 4.8): a helper with no gate, another cut's gate, the marks, where a
	cutter places its gate. Each returns the report that stops the op, or nil; the caller stops the run. Too large a
	given state is Full, an unusable clock Undecided. GatedReport assumes G lacks the op's name.

	Return type: A plain table with GatedReport and PlaceGateForMarks.
	Example usage:
		local Stopping = Gate.GatedReport(Run, Form)
		local Marked = Gate.PlaceGateForMarks(Run, Op, Form)
--]=]

local Book = require("../../Stored/Book")
local CutShapes = require("../Shapes")
local Entries = require("../../Stored/Entries")
local Json = require("../../Encoding/Json")
local Judge = require("../../Judging/Judge")
local JudgingRun = require("../../Judging/Run")
local JudgingShapes = require("../../Judging/Shapes")
local Marks = require("../../Tx/Legs/Marks")
local Record = require("../../Constants/Record")
local Shapes = require("../../Shapes")
local Timed = require("../../Stored/Items/Timed")
local Value = require("../../Stored/Value")
local Work = require("../../Stored/Items/Work")

type Fields = Value.Fields
type Mark = Work.Mark
type CutKind = Timed.CutKind
type CutForm = CutShapes.CutForm
type Limits = Shapes.Limits
type Report = JudgingShapes.Report
type Run = JudgingRun.Run
type SentOp = Shapes.SentOp
type Book = Book.Book

local FingerprintOf = Entries.FingerprintOf
local PlainName = Entries.PlainName
local IsClockUsable = Judge.IsClockUsable

local DataStoreValueMax = Record.DataStoreValueMax

local function CutMarks(Working: Book, Kind: CutKind): { Mark }
	local Listed = Marks.MarksIn(Working)
	if Kind == "Reset" then
		return Listed
	end
	for _, Pinned in Marks.PinnedIn(Working) do
		table.insert(Listed, Pinned)
	end
	return Listed
end

local function GatedReport(Run: Run, Form: CutForm): Report?
	if Form.Role == "Helper" then
		return { Kind = "Gone" }
	end
	local Gate = Run.Book.Gate
	if Gate ~= nil then
		return { Kind = "GatedBy", Gate = Gate, Marks = CutMarks(Run.Book, Gate.Kind) }
	end
	return nil
end

local function GateFits(State: Fields, Given: Fields, Limits: Limits): boolean
	return Json.Size(State) + Json.Size(Given) + Limits.BookMax <= DataStoreValueMax
end

local function PlaceGate(Run: Run, Op: SentOp, Form: CutForm)
	Run.Book.Gate = {
		Kind = Form.CutKind,
		Name = PlainName(Form.Name),
		Stamp = Op.Stamp,
		PlacedAt = Run.Clock,
		Fingerprint = FingerprintOf(Form.Name),
	}
	Run.Given = Form.Given
	Run.Acted = true
end

local function PlaceGateForMarks(Run: Run, Op: SentOp, Form: CutForm): Report?
	local Standing = CutMarks(Run.Book, Form.CutKind)
	if #Standing == 0 then
		return nil
	end
	if Run.Book.Gate == nil and Form.Role == "Cutter" then
		if Form.Given ~= nil and not GateFits(Run.State, Form.Given, Run.Setup.Limits) then
			return { Kind = "Full" }
		end
		if not IsClockUsable(Run.Clock, Run.Setup.Limits) then
			return { Kind = "Undecided" }
		end
		PlaceGate(Run, Op, Form)
	end
	return { Kind = "Marks", Marks = Standing }
end

return {
	GatedReport = GatedReport,
	PlaceGateForMarks = PlaceGateForMarks,
}
