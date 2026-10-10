--!strict
--!optimize 2

--[=[
	Verdicts: what a walk's step, fence or step Tx report means for its call (sheet H6): took, a part's refusal or a
	fence, either of which moves the walk on, or an answer. Reports reads a live walk's reports with it, Outcomes a
	report heard after the walk answered, so both read them one way.

	Return type: A plain table with StepVerdict, FenceVerdict and TxStepVerdict, and the Verdict type.
	Example usage:
		local Heard = Verdicts.StepVerdict(Out.Reason, Out.Report)
--]=]

local Events = require("../../Events")
local Fates = require("../../Stored/Items/Fates")
local JudgingShapes = require("../../Judging/Shapes")
local Reasons = require("../../Constants/Reasons")
local StepAnswer = require("../../Tx/Call/StepAnswer")

type Answer = Events.Answer
type Fate = Fates.Fate
type PartReason = Fates.PartReason
type Reason = Reasons.Reason
type Report = JudgingShapes.Report

export type Verdict =
	{ read Kind: "Took", read Fate: Fate }
	| { read Kind: "Refused", read Reason: PartReason }
	| { read Kind: "Fenced" }
	| { read Kind: "Answers", read Given: Answer }

local ModuleName = "Verdicts"
local RoutingFault = `{ModuleName}: this call is never made.`
local NoReason = `{RoutingFault} A step that is neither took nor a part's no was answered with a reason.`
local NoFenceReason = `{RoutingFault} A fence on a part reports no such thing.`

local FencedVerdict: Verdict = table.freeze({ Kind = "Fenced" :: "Fenced" })

local function AnswersWith(Reason: Reason?): Verdict
	if Reason == nil then
		error(NoReason)
	end
	return { Kind = "Answers", Given = { Kind = "Failed", Reason = Reason, State = nil } }
end

local function TookVerdict(Value: number?): Verdict
	local Fate: Fate = if Value ~= nil then { Kind = "TookWith", Value = Value } else { Kind = "Took" }
	return { Kind = "Took", Fate = Fate }
end

local function StepVerdict(Reason: Reason?, Report: Report): Verdict
	if Report.Kind ~= "Fated" then
		return AnswersWith(Reason)
	end
	local Fate = Report.Fate
	if Fate.Kind == "Took" or Fate.Kind == "TookWith" then
		return { Kind = "Took", Fate = Fate }
	end
	if Fate.Kind == "RefusedFor" then
		return { Kind = "Refused", Reason = Fate.Reason }
	end
	if Fate.Kind == "Fenced" then
		return FencedVerdict
	end
	return AnswersWith(Reason)
end

local function StoredRefusalOf(Fate: Fate): Reason
	if Fate.Kind == "Full" then
		return Reasons.Full
	end
	return Reasons.Refused
end

local function FenceReasonOf(Report: Report): Reason
	if Report.Kind == "Other" then
		return Reasons.Spent
	end
	if Report.Kind == "Refused" then
		return StoredRefusalOf(Report.Fate)
	end
	if Report.Kind == "Missing" then
		return Reasons.Missing
	end
	if Report.Kind == "Behind" then
		return Reasons.Behind
	end
	if Report.Kind == "NoRoom" and #Report.Marks == 0 then
		return Reasons.NoRoom
	end
	if
		Report.Kind == "NoRoom"
		or Report.Kind == "Forgotten"
		or Report.Kind == "Unreadable"
		or Report.Kind == "Worn"
	then
		return Reasons.Unresolved
	end
	error(NoFenceReason)
end

local function FenceVerdict(Report: Report): Verdict
	if Report.Kind == "Fenced" then
		return FencedVerdict
	end
	if Report.Kind == "Committed" then
		return TookVerdict(Report.DeciderValue)
	end
	if Report.Kind == "Refused" and Report.Fate.Kind == "RefusedFor" then
		return { Kind = "Refused", Reason = Report.Fate.Reason }
	end
	return AnswersWith(FenceReasonOf(Report))
end

local function TxStepVerdict(Taken: StepAnswer.StepAnswer): Verdict
	local Given = Taken.Given
	if Given.Kind == "Succeeded" then
		return TookVerdict(Taken.DeciderValue)
	end
	local Refusal = Taken.DeciderFate
	if Refusal ~= nil and Refusal.Kind == "RefusedFor" then
		return { Kind = "Refused", Reason = Refusal.Reason }
	end
	if Refusal ~= nil and Refusal.Kind == "Fenced" then
		return FencedVerdict
	end
	return { Kind = "Answers", Given = Given }
end

return {
	StepVerdict = StepVerdict,
	FenceVerdict = FenceVerdict,
	TxStepVerdict = TxStepVerdict,
}
