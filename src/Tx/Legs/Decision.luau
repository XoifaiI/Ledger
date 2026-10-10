--!strict
--!optimize 2

--[=[
	Decision: what a read of a decider shows of a mark's use, and the ends that follow (sheets 16, 18.3). Gone is
	orphan evidence after OrphanAge. Absent or sealed is undecided before LatestCommitCreate (sheet 9 rule 0): the
	widest window, never before W[tx], plus T_step's margin for skew, a read ReadLag stale, a Commit landing Delay
	late.

	Return type: A plain table with FenceFor, ResolveFor, OrphanEnd, IsOrphanEvidence, DecisionShown,
	AbsentDeciderSays and FenceSays, and the DeciderSays type.
	Example usage:
		local Says = Decision.DecisionShown(Kept, Mark.Opening)
--]=]

local Fates = require("../../Stored/Items/Fates")
local JudgingShapes = require("../../Judging/Shapes")
local Marks = require("./Marks")
local Shapes = require("../../Shapes")
local TxShapes = require("../Shapes")
local Value = require("../../Stored/Value")
local Work = require("../../Stored/Items/Work")

type Fate = Fates.Fate
type FenceEnd = TxShapes.FenceEnd
type ResolveEnd = TxShapes.ResolveEnd
type TxOutcome = TxShapes.TxOutcome
type Report = JudgingShapes.Report
type Kept = Value.Kept
type Limits = Shapes.Limits
type MarkOpening = Work.MarkOpening
type StandingMark = Work.StandingMark

export type DeciderSays =
	{ read Kind: "Gone" }
	| { read Kind: "Commit", read Attempt: number, read DeciderValue: number? }
	| { read Kind: "Abort" }
	| { read Kind: "Undecided" }

local GoneSays: DeciderSays = table.freeze({ Kind = "Gone" :: "Gone" })
local AbortSays: DeciderSays = table.freeze({ Kind = "Abort" :: "Abort" })
local UndecidedSays: DeciderSays = table.freeze({ Kind = "Undecided" :: "Undecided" })

local function FenceFor(Mark: StandingMark): FenceEnd
	local Opening = Mark.Opening
	return {
		Kind = "Fence",
		Name = Marks.OpNameOf(Opening),
		Stamp = Opening.Stamp,
		Attempt = Opening.Attempt,
		IsFinal = false,
	}
end

local function CommitEnd(Blocker: StandingMark, Attempt: number, DeciderValue: number?): ResolveEnd
	local Opening = Blocker.Opening
	return {
		Kind = "Resolve",
		Name = Marks.OpNameOf(Opening),
		Stamp = Opening.Stamp,
		Attempt = Attempt,
		Outcome = "Commit",
		Decider = table.clone(Blocker.Decider),
		DeciderValue = DeciderValue,
	}
end

local function EndAtMarkAttempt(Blocker: StandingMark, Outcome: TxOutcome): ResolveEnd
	local Opening = Blocker.Opening
	return {
		Kind = "Resolve",
		Name = Marks.OpNameOf(Opening),
		Stamp = Opening.Stamp,
		Attempt = Opening.Attempt,
		Outcome = Outcome,
		Decider = table.clone(Blocker.Decider),
	}
end

local function ResolveFor(Blocker: StandingMark, Says: DeciderSays): ResolveEnd?
	if Says.Kind == "Commit" then
		return CommitEnd(Blocker, Says.Attempt, Says.DeciderValue)
	end
	if Says.Kind == "Abort" then
		return EndAtMarkAttempt(Blocker, "Abort")
	end
	return nil
end

local function OrphanEnd(Blocker: StandingMark): ResolveEnd
	return EndAtMarkAttempt(Blocker, "Orphan")
end

local function IsOrphanEvidence(Says: DeciderSays, AskedAt: number, Stamp: number, OrphanAge: number): boolean
	return Says.Kind == "Gone" and AskedAt - Stamp >= OrphanAge
end

local function WidestWindow(Windows: { [string]: number }): number
	local Widest = 0
	for _, Window in Windows do
		Widest = math.max(Widest, Window)
	end
	return Widest
end

local function LatestCommitCreate(Opening: MarkOpening, Limits: Limits): number
	return Opening.Stamp + WidestWindow(Limits.TimedWindows) + Limits.TouchStep
end

local function AbsentDeciderSays(Opening: MarkOpening, AskedAt: number, Limits: Limits): DeciderSays
	if AskedAt < LatestCommitCreate(Opening, Limits) then
		return UndecidedSays
	end
	return GoneSays
end

local function SaysOfDecision(Fate: Fate, Attempt: number): DeciderSays
	if Fate.Kind == "Took" then
		return { Kind = "Commit", Attempt = Attempt, DeciderValue = nil }
	end
	if Fate.Kind == "TookWith" then
		return { Kind = "Commit", Attempt = Attempt, DeciderValue = Fate.Value }
	end
	if Fate.Kind == "Refused" or Fate.Kind == "Full" or Fate.Kind == "RefusedFor" then
		return AbortSays
	end
	if Fate.Kind == "Fenced" and (Fate.IsFinal or Fate.Attempt >= Attempt) then
		return AbortSays
	end
	return UndecidedSays
end

local function DecisionShown(Kept: Kept?, Opening: MarkOpening): DeciderSays
	if Kept == nil then
		return GoneSays
	end
	local Held = Kept.Book
	local Name = Marks.OpNameOf(Opening)
	local Pinned = Marks.OwnPinnedOf(Held, Name)
	if Pinned ~= nil then
		return { Kind = "Commit", Attempt = Pinned.Opening.Attempt, DeciderValue = Pinned.DeciderValue }
	end
	local Decision = Marks.OwnEntryOf(Held, Name)
	if Decision ~= nil then
		return SaysOfDecision(Decision.Fate, Opening.Attempt)
	end
	if Marks.IsForgotten(Held, Name, Opening.Stamp) then
		return AbortSays
	end
	return UndecidedSays
end

local function FenceSays(Report: Report?): DeciderSays
	if Report == nil then
		return UndecidedSays
	end
	if Report.Kind == "Committed" then
		return { Kind = "Commit", Attempt = Report.Attempt, DeciderValue = Report.DeciderValue }
	end
	if Report.Kind == "Fenced" or Report.Kind == "Refused" or Report.Kind == "Forgotten" then
		return AbortSays
	end
	return UndecidedSays
end

return {
	FenceFor = FenceFor,
	ResolveFor = ResolveFor,
	OrphanEnd = OrphanEnd,
	IsOrphanEvidence = IsOrphanEvidence,
	DecisionShown = DecisionShown,
	AbsentDeciderSays = AbsentDeciderSays,
	FenceSays = FenceSays,
}
