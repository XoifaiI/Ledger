--!strict
--!optimize 2

--[=[
	Tent: the judgement of a Tent on a leg key that is not the decider (transaction sheet 8).

	Removing an older mark of this use sets Acted, so the write lands though a later rule reports without writing. A
	game leg's mark keeps its slot; past MarkMax it reports Large. A delta leg on a rejected balance reports Unreadable
	(Balance).

	Return type: A plain table with TentLookup, TentGate and JudgeTent.
	Example usage:
		local Held = Tent.TentLookup(Run, Form)
--]=]

local Balances = require("./Balances")
local Decide = require("../../Judging/Decide")
local Entries = require("../../Stored/Entries")
local Guards = require("../../Judging/Guards")
local JudgingRun = require("../../Judging/Run")
local JudgingShapes = require("../../Judging/Shapes")
local Lookup = require("../../Stored/Lookup")
local Marks = require("./Marks")
local Post = require("../../Stored/Post")
local PostDiff = require("./PostDiff")
local Shapes = require("../../Shapes")
local TxShapes = require("../Shapes")
local Work = require("../../Stored/Items/Work")

type GameLeg = TxShapes.GameLeg
type TentForm = TxShapes.TentForm
type Report = JudgingShapes.Report
type Run = JudgingRun.Run
type SentOp = Shapes.SentOp
type Mark = Work.Mark
type DiffEntry = Post.DiffEntry

local FingerprintOf = Entries.FingerprintOf

local LargeReport: Report = table.freeze({ Kind = "Large" :: "Large" })

local SlotProbeValue = 1

local ModuleName = "Tent"
local DeltaNotDeclared =
	`{ModuleName}: a delta leg's op kind is a balance op the build declares. This one is not, so the leg is wrong`

local function TentLookup(Run: Run, Form: TentForm): Report?
	local Working = Run.Book
	local Name = Form.Name
	local Found = Marks.MarksOf(Working, Name)
	for _, Item in Found do
		if Item.Opening.Fingerprint ~= FingerprintOf(Name) then
			return { Kind = "Other" }
		end
	end
	local Own = Found[1]
	if Own ~= nil then
		if Own.Opening.Attempt == Form.Attempt then
			return { Kind = "Mine", Attempt = Form.Attempt }
		end
		if Own.Opening.Attempt > Form.Attempt then
			return { Kind = "Superseded", Attempt = Own.Opening.Attempt }
		end
		Marks.RemoveWorkItem(Run, Own)
		Run.Acted = true
	end
	if Marks.HasOtherEntry(Working, Name) then
		return { Kind = "Other" }
	end
	local Entry = Marks.OwnEntryOf(Working, Name)
	if Entry ~= nil then
		local Fate = Entry.Fate
		if Fate.Kind == "Aborted" then
			if Fate.Attempt >= Form.Attempt then
				return { Kind = "Decided", Fate = Fate }
			end
		elseif Fate.Kind == "Took" or Fate.Kind == "Refused" or Fate.Kind == "Full" then
			return { Kind = "Decided", Fate = Fate }
		else
			return { Kind = "Other" }
		end
	end
	if Marks.PinnedOf(Working, Name) ~= nil or Lookup.HasUntimedOrCutName(Working, Name) then
		return { Kind = "Other" }
	end
	return nil
end

local function TentGate(Run: Run): Report?
	local Gate = Run.Book.Gate
	if Gate == nil then
		return nil
	end
	return { Kind = "Gated", Gate = Gate }
end

local function PlaceLegMark(Run: Run, Op: SentOp, Form: TentForm, Item: Mark): Report
	Marks.PlaceWorkItem(Run, Item)
	table.insert(Run.Decided, Op)
	return { Kind = "Mine", Attempt = Form.Attempt }
end

local function JudgeDeltaLeg(Run: Run, Op: SentOp, Form: TentForm, Amount: unknown): Report
	local Exclusive = Marks.ExclusiveOf(Run.Book)
	if Exclusive ~= nil then
		return Marks.BlockedReport({ Exclusive }, Run.Setup.Limits)
	end
	local Declaration = Run.Setup.Build.BalanceOps[Op.OpKind]
	if Declaration == nil then
		error(DeltaNotDeclared)
	end
	local Escrows = Marks.EscrowMarksOf(Run.Book.Work)
	local Verdict = Balances.Judge(Run.State, Escrows, Declaration, Amount)
	if Verdict == Balances.Verdict.Unreadable then
		return { Kind = "Unreadable", Cause = "Amounts" }
	end
	if Verdict == Balances.Verdict.InvalidBalance then
		return { Kind = "Unreadable", Cause = "Balance" }
	end
	if Verdict == Balances.Verdict.Invalid then
		return { Kind = "Invalid" }
	end
	if Verdict == Balances.Verdict.Refused then
		return Marks.WriteRefusal(Run, Op, Form.Name, { Kind = "Refused" })
	end
	local Opening = Marks.NewOpening(Form.Name, Op.Stamp, Form.Attempt)
	local Item = Marks.NewEscrowMark(Opening, Form.Decider, Declaration, Amount)
	if not Marks.HasPlaceFor(Run, Item) then
		return Marks.NoRoomReport(Run, Item)
	end
	return PlaceLegMark(Run, Op, Form, Item)
end

local function IsSlotWritable(Run: Run, Diff: { DiffEntry }, Leg: GameLeg): boolean
	if Leg.Slot == nil then
		return true
	end
	local Slotted = PostDiff.WriteSlot(Diff, Leg.Slot, SlotProbeValue)
	if not PostDiff.Applies(Run.State, Slotted) then
		return false
	end
	return Guards.Storable(PostDiff.ApplyDiff(Run.State, Slotted), ModuleName) == nil
end

local function JudgeGameLeg(Run: Run, Op: SentOp, Form: TentForm, Leg: GameLeg): Report
	local Standing = Marks.MarksIn(Run.Book)
	if #Standing > 0 then
		return Marks.BlockedReport(Standing, Run.Setup.Limits)
	end
	local Verdict = Decide.DecideOnState(Run.Setup, Run.State, Op.OpKind, Op.Terms, Decide.NoMarks, Run.Clock)
	if Verdict.Kind ~= "Took" then
		return Marks.RefuseOrStop(Run, Op, Form.Name, Verdict)
	end
	local Diff = PostDiff.DiffStates(Run.State, Verdict.State)
	if PostDiff.DiffBytes(Diff) > Run.Setup.Limits.PostCap then
		return LargeReport
	end
	local Opening = Marks.NewOpening(Form.Name, Op.Stamp, Form.Attempt)
	local Item = Marks.NewExclusiveMark(Opening, Form.Decider, Leg.Slot)
	if not Marks.IsWithinMarkMax(Run, Item) then
		return LargeReport
	end
	if not IsSlotWritable(Run, Diff, Leg) then
		return Marks.WriteRefusal(Run, Op, Form.Name, { Kind = "Refused" })
	end
	if not Marks.HasPlaceFor(Run, Item) then
		return Marks.NoRoomReport(Run, Item)
	end
	Run.Post = Diff
	return PlaceLegMark(Run, Op, Form, Item)
end

local function JudgeTent(Run: Run, Op: SentOp, Form: TentForm): Report
	local Leg = Form.Leg
	if Leg.Kind == "Delta" then
		return JudgeDeltaLeg(Run, Op, Form, Leg.Amount)
	end
	return JudgeGameLeg(Run, Op, Form, Leg)
end

return {
	TentLookup = TentLookup,
	TentGate = TentGate,
	JudgeTent = JudgeTent,
}
