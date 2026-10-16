--!strict
--!optimize 2

--[=[
	Transform: the one order of every write to a key, judged by its kind's Setup (record sheet 9).

	A request that decides and changes nothing cancels; a tidy lands only if age dropped an item. On a part,
	holds expire before the guards, an open on a held key cancels as took, and a drained final part seals (H4).

	Return type: A plain table with Step, and the Output type.
	Example usage:
		local Output, Note = Transform.Step(Stored, Request, Clock, Setup, Closure, "Game")
--]=]

local Book = require("../Stored/Book")
local CutOp = require("../Cuts/Rules/CutOp")
local Decide = require("./Decide")
local Ends = require("../Tx/Legs/Ends")
local EntryUpdate = require("./EntryUpdate")
local Fold = require("../Cuts/Rules/Fold")
local Holds = require("../Hot/Part/Holds")
local Judge = require("./Judge")
local JudgingRun = require("./Run")
local JudgingShapes = require("./Shapes")
local KindSetup = require("./KindSetup")
local Marks = require("../Tx/Legs/Marks")
local Notes = require("./Notes")
local Opening = require("./Opening")
local PartOps = require("../Hot/Part/Ops")
local Record = require("../Constants/Record")
local Rooms = require("../Stored/Rooms")
local Shapes = require("../Shapes")
local Value = require("../Stored/Value")

type Kept = Value.Kept
type Setup = Shapes.Setup
type KeyKind = Shapes.KeyKind
type Closure = JudgingShapes.Closure
type Request = Shapes.Request
type UpdateRequest = Shapes.UpdateRequest
type Report = JudgingShapes.Report
type NoteWarning = JudgingShapes.NoteWarning
type Note = JudgingShapes.Note
type Run = JudgingRun.Run
type Book = Book.Book
type Shown = Notes.Shown
type Ending = Notes.Ending

export type Output = Notes.Output

local PartKind = Record.KeyKind.Part

local ModuleName = "Transform"
local NoOpsToJudge =
	`{ModuleName}: a ProveGone or a SealStamp opens as a seal to write or shuts. The caller must not judge ops for one`

local IsClockUsable = Judge.IsClockUsable
local OpenKey = Opening.OpenKey
local GuardReport = Opening.GuardReport

local function IsMadeByTxOp(Request: UpdateRequest, IsMade: boolean): boolean
	if not IsMade then
		return false
	end
	local Kind = Request.Ops[1].Form.Kind
	return Kind == "Tent" or Kind == "Commit"
end

local function NewRun(
	Key: Kept,
	Request: UpdateRequest,
	Clock: number,
	Setup: Setup,
	Closure: Closure,
	Kind: KeyKind,
	IsMade: boolean
): Run
	return {
		Book = Key.Book,
		State = Key.State,
		Epoch = nil,
		Kind = Kind,
		Request = Request,
		Clock = Clock,
		Setup = Setup,
		Closure = { Wrote = Closure.Wrote, Ran = table.clone(Closure.Ran) },
		Reports = {},
		Decided = {},
		NewFates = {},
		Written = {},
		Warnings = {},
		IsStopped = false,
		MigrationsTried = false,
		Post = Key.Post,
		Acted = IsMadeByTxOp(Request, IsMade),
		Placed = nil,
		Given = Key.Given,
		Sealed = nil,
	}
end

local function AgeKey(Key: Kept, Run: Run): boolean
	local Limits = Run.Setup.Limits
	if not IsClockUsable(Run.Clock, Limits) then
		return false
	end
	local ItemsBefore = Rooms.CountItems(Run.Book)
	local IsGateDropped = Rooms.Age(Run.Book, Run.Clock, Run.Request.WriterId, Limits)
	if IsGateDropped then
		Key.Given = nil
	end
	return Rooms.CountItems(Run.Book) < ItemsBefore
end

local function FitKey(Run: Run)
	local Limits = Run.Setup.Limits
	local Epoch = Rooms.EpochOf(Run.Book)
	if Epoch ~= nil then
		Rooms.FitTimed(Run.Book, Run.Clock, Run.Written, Epoch, Run.Kind, Limits)
	end
	Rooms.FitCutNames(Run.Book, Limits)
	if not Fold.IsOver(Run.Book, Limits, Run.Kind) then
		return
	end
	if IsClockUsable(Run.Clock, Limits) then
		Fold.FitLosses(Run.Book, Run.Clock, Run.Setup, Run.Kind)
	else
		Fold.FitReturns(Run.Book, Run.Setup, Run.Kind)
	end
end

local function CancellingIn(Reports: { Report }): Report?
	for _, Report in Reports do
		if Decide.StopOf(Report) ~= nil then
			return Report
		end
	end
	return nil
end

local function IsTidy(Request: UpdateRequest): boolean
	return #Request.Ops == 0 and #Request.Ends == 0
end

local function IsCutRequest(Request: UpdateRequest): boolean
	local First = Request.Ops[1]
	return First ~= nil and First.Form.Kind == "Cut"
end

local function JudgeAllOps(Run: Run)
	Run.Epoch = Rooms.EpochOf(Run.Book)
	if IsCutRequest(Run.Request) then
		CutOp.JudgeCuts(Run)
	elseif Run.Kind == PartKind and PartOps.IsOpenRequest(Run.Request) then
		PartOps.JudgeOpen(Run)
	else
		Judge.JudgeOps(Run)
	end
	EntryUpdate.MarkRan(Run)
end

local function RunOps(Key: Kept, Run: Run, Shown: Shown, WarningsIfLanded: { NoteWarning }): (Output, Note)
	local EndReports = Ends.ApplyEnds(Run)
	local EndsCancelling = CancellingIn(EndReports)
	if EndsCancelling ~= nil then
		return Notes.CancelWith(Run.Request, EndsCancelling, Shown, Run.Closure, Run.Warnings)
	end
	JudgeAllOps(Run)
	local OpCancelling = CancellingIn(Run.Reports)
	if OpCancelling ~= nil then
		return Notes.CancelAtOp(Run.Request, OpCancelling, Shown, Run.Closure, Run.Warnings)
	end
	local Ending: Ending =
		{ Reports = Run.Reports, ProbeReport = nil, Warnings = Run.Warnings, EndReports = EndReports }
	if #Run.Decided == 0 and not Run.Acted and not IsTidy(Run.Request) then
		return Notes.Cancelled, Notes.BuildNote(Shown, Run.Closure, Ending, nil)
	end
	if Run.Kind == PartKind then
		Holds.SealIfDone(Run)
	end
	if Run.Sealed ~= nil then
		return Notes.LandSeal(Run.Sealed, Run.Setup, Run.Closure, Ending)
	end
	if Run.State ~= Key.State then
		Marks.ClearCleanFlags(Run.Book, Run.Placed)
	end
	Key.State = Run.State
	Key.Post = Run.Post
	Key.Given = Run.Given
	table.move(WarningsIfLanded, 1, #WarningsIfLanded, #Run.Warnings + 1, Run.Warnings)
	EntryUpdate.UpdateEntry(Run)
	local HasAgedItems = AgeKey(Key, Run)
	if IsTidy(Run.Request) and not HasAgedItems then
		return Notes.Cancelled, Notes.BuildNote(Shown, Run.Closure, Ending, nil)
	end
	FitKey(Run)
	return Notes.Land(Key, Run.Setup, Run.Closure, Ending)
end

local function Step(
	Stored: unknown,
	Request: Request,
	Clock: number,
	StoreSetup: Setup,
	Closure: Closure,
	Kind: KeyKind
): (Output, Note)
	local Setup = KindSetup.SetupFor(StoreSetup, Kind)
	local Opened = OpenKey(Stored, Request, Setup, Closure, Clock)
	if Opened.Kind == "Seal" then
		local Proving: Ending = { Reports = {}, ProbeReport = Opened.Report, Warnings = {}, EndReports = {} }
		return Notes.LandSeal(Opened.Seal, Setup, Closure, Proving)
	end
	if Opened.Kind == "ShutEach" then
		return Notes.CancelEach(Opened.Reports, Opened.EndReports, Notes.NothingShown, Closure)
	end
	local Shown = Notes.NothingShown
	if Opened.Kind == "Open" and not Opened.IsMade then
		Shown = Notes.ShownOf(Opened.Key)
	end
	if Opened.Kind == "Shut" then
		return Notes.CancelWith(Request, Opened.Report, Shown, Closure, {})
	end
	local Key = Opened.Key
	if Kind == PartKind and not Opened.IsMade and PartOps.IsOpenRequest(Request) then
		return Notes.CancelWith(Request, PartOps.OpenedReport(), Shown, Closure, {})
	end
	if Kind == PartKind and IsClockUsable(Clock, Setup.Limits) then
		Holds.ExpireHolds(Key, Clock, Setup.Limits)
	end
	local Guarded = GuardReport(Key.Book, Request, Clock, Setup.Limits)
	if Guarded ~= nil then
		return Notes.CancelWith(Request, Guarded, Shown, Closure, {})
	end
	if Request.Kind == "Fresh" then
		local Fresh: Ending = { Reports = {}, ProbeReport = nil, Warnings = {}, EndReports = {} }
		return Notes.Land(Key, Setup, Closure, Fresh)
	end
	if Request.Kind == "Probe" then
		local Probed = Notes.ProbeReportOf(Key.Book, Request.Name, Request.Stamp)
		if Probed.Kind ~= "Landed" then
			return Notes.CancelWith(Request, Probed, Shown, Closure, {})
		end
		local Landing: Ending = { Reports = {}, ProbeReport = Probed, Warnings = {}, EndReports = {} }
		return Notes.Land(Key, Setup, Closure, Landing)
	end
	if Request.Kind ~= "Update" then
		error(NoOpsToJudge)
	end
	local Run = NewRun(Key, Request, Clock, Setup, Closure, Kind, Opened.IsMade)
	return RunOps(Key, Run, Shown, Opened.WarningsIfLanded)
end

return {
	Step = Step,
}
