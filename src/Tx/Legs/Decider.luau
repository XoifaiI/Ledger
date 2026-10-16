--!strict
--!optimize 2

--[=[
	Decider: the Commit and the Fence on the decider D (transaction sheets 9, 10) and the Commit's create window
	(3.3).

	A Commit makes its key only within its leg's window, unrounded. Only an erase gate stops it. Past MarkMax it
	reports Large. A took's value (a part's serial) goes in the pinned record and the report. Fence is an end.

	Return type: A plain table with CommitMayCreate, CommitLookup, CommitGate, JudgeCommit and Fence.
	Example usage:
		if Decider.CommitMayCreate(Op, Clock, Limits) then ... end
--]=]

local Decide = require("../../Judging/Decide")
local Entries = require("../../Stored/Entries")
local Fates = require("../../Stored/Items/Fates")
local JudgingRun = require("../../Judging/Run")
local JudgingShapes = require("../../Judging/Shapes")
local Lookup = require("../../Stored/Lookup")
local Marks = require("./Marks")
local OrderRule = require("./OrderRule")
local Shapes = require("../../Shapes")
local TxShapes = require("../Shapes")
local Work = require("../../Stored/Items/Work")

type CommitForm = TxShapes.CommitForm
type FenceEnd = TxShapes.FenceEnd
type Fate = Fates.Fate
type Limits = Shapes.Limits
type Report = JudgingShapes.Report
type Run = JudgingRun.Run
type SentOp = Shapes.SentOp
type Mark = Work.Mark
type PinnedRecord = Work.PinnedRecord

local FingerprintOf = Entries.FingerprintOf

local LargeReport: Report = table.freeze({ Kind = "Large" :: "Large" })

local function CommitMayCreate(Op: SentOp, Clock: number, Limits: Limits): boolean
	return Clock - Op.Stamp <= Entries.WindowOf(Limits.TimedWindows, Op.OpKind)
end

local function PinnedReport(Pinned: PinnedRecord): Report
	return { Kind = "Committed", Attempt = Pinned.Opening.Attempt, DeciderValue = Pinned.DeciderValue }
end

local function FateReport(Fate: Fate, Attempt: number): Report
	if Fate.Kind == "Took" then
		return { Kind = "Committed", Attempt = Attempt, DeciderValue = nil }
	end
	if Fate.Kind == "TookWith" then
		return { Kind = "Committed", Attempt = Attempt, DeciderValue = Fate.Value }
	end
	if Fate.Kind == "Refused" or Fate.Kind == "Full" or Fate.Kind == "RefusedFor" then
		return { Kind = "Refused", Fate = Fate, State = nil }
	end
	return { Kind = "Other" }
end

local function DecisionReport(Run: Run, Form: CommitForm): Report?
	local Entry = Marks.OwnEntryOf(Run.Book, Form.Name)
	if Entry == nil then
		return nil
	end
	local Fate = Entry.Fate
	if Fate.Kind ~= "Fenced" then
		return FateReport(Fate, Form.Attempt)
	end
	if Fate.IsFinal or Fate.Attempt >= Form.Attempt then
		return { Kind = "Fenced", Attempt = Fate.Attempt, IsFinal = Fate.IsFinal }
	end
	return nil
end

local function CommitLookup(Run: Run, Form: CommitForm): Report?
	local Working = Run.Book
	local Name = Form.Name
	local Pinned = Marks.PinnedOf(Working, Name)
	if Pinned ~= nil then
		if Pinned.Opening.Fingerprint ~= FingerprintOf(Name) then
			return { Kind = "Other" }
		end
		return PinnedReport(Pinned)
	end
	if Marks.HasOtherEntry(Working, Name) then
		return { Kind = "Other" }
	end
	local Decision = DecisionReport(Run, Form)
	if Decision ~= nil then
		return Decision
	end
	if #Marks.MarksOf(Working, Name) > 0 or Lookup.HasUntimedOrCutName(Working, Name) then
		return { Kind = "Other" }
	end
	return nil
end

local function CommitGate(Run: Run): Report?
	local Gate = Run.Book.Gate
	if Gate == nil or Gate.Kind ~= "Erase" then
		return nil
	end
	return { Kind = "Gated", Gate = Gate }
end

local function JudgeCommit(Run: Run, Op: SentOp, Form: CommitForm): Report
	local Stopping = OrderRule.JudgeOrder(Run, Op)
	if Stopping ~= nil then
		return Stopping
	end
	local Escrows = Marks.EscrowMarksOf(Run.Book.Work)
	local Verdict = Decide.DecideOnState(Run.Setup, Run.State, Op.OpKind, Op.Terms, Escrows, Run.Clock)
	if Verdict.Kind ~= "Took" and Verdict.Kind ~= "TookWith" then
		return Marks.RefuseOrStop(Run, Op, Form.Name, Verdict)
	end
	local DeciderValue: number? = nil
	if Verdict.Kind == "TookWith" then
		DeciderValue = Verdict.Value
	end
	local Opening = Marks.NewOpening(Form.Name, Op.Stamp, Form.Attempt)
	local Pinned = Marks.NewPinnedRecord(Opening, Form.OtherLegs, DeciderValue)
	if not Marks.IsWithinMarkMax(Run, Pinned) then
		return LargeReport
	end
	if not Marks.HasPlaceFor(Run, Pinned) then
		if Marks.CountPinned(Run.Book) >= Run.Setup.Limits.OwedCap then
			return { Kind = "Owed", Marks = Marks.PinnedIn(Run.Book) }
		end
		return Marks.NoRoomReport(Run, Pinned)
	end
	Run.State = Verdict.State
	Marks.RemoveNamed(Run, Form.Name)
	Marks.PlaceWorkItem(Run, Pinned)
	table.insert(Run.Decided, Op)
	return { Kind = "Committed", Attempt = Form.Attempt, DeciderValue = DeciderValue }
end

local function WriteFence(Run: Run, End: FenceEnd, Stamp: number, Attempt: number, IsFinal: boolean): Report
	Marks.WriteEndFate(Run, End.Name, Stamp, { Kind = "Fenced", Attempt = Attempt, IsFinal = IsFinal })
	Run.Acted = true
	return { Kind = "Fenced", Attempt = Attempt, IsFinal = IsFinal }
end

local function Fence(Run: Run, End: FenceEnd): Report
	local Working = Run.Book
	local Pinned = Marks.OwnPinnedOf(Working, End.Name)
	if Pinned ~= nil then
		return PinnedReport(Pinned)
	end
	local Decision = Marks.OwnEntryOf(Working, End.Name)
	if Decision == nil then
		if Marks.IsForgotten(Working, End.Name, End.Stamp) then
			return { Kind = "Forgotten" }
		end
		return WriteFence(Run, End, End.Stamp, End.Attempt, End.IsFinal)
	end
	local Fate = Decision.Fate
	if Fate.Kind ~= "Fenced" then
		return FateReport(Fate, End.Attempt)
	end
	if Fate.Attempt >= End.Attempt and (Fate.IsFinal or not End.IsFinal) then
		return { Kind = "Fenced", Attempt = Fate.Attempt, IsFinal = Fate.IsFinal }
	end
	return WriteFence(Run, End, Decision.Stamp, math.max(Fate.Attempt, End.Attempt), Fate.IsFinal or End.IsFinal)
end

return {
	CommitMayCreate = CommitMayCreate,
	CommitLookup = CommitLookup,
	CommitGate = CommitGate,
	JudgeCommit = JudgeCommit,
	Fence = Fence,
}
