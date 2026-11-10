--!strict
--!optimize 2

--[=[
	OneAnswer: how a game named walk's step answers for the name x, not only for its own sub name (hot keys sheet H6a).
	A step whose Tent reported Served fences the sibling sub name that took and answers true when that fence commits.
	A step whose own final fence meets no sub name that took, after Other, Large or its own took, sweeps: it fences
	each later part of its walk in turn, answers true by the first that committed, else Spent. A Commit that reports
	Other sweeps with no fence of its own part, which already holds the name. A fence of a sibling that reports
	anything else, or errs past RetryRounds, answers Unresolved. It records on the call that marks of its own may
	stand and whether its own part is already fenced (OwnMarksStanding); AfterAnswer ends them. It alone reads what a
	game named step's final fence was sent for (FenceFor).

	Return type: A plain table with ServedPartOf, FenceServed, FenceAfterTents, FenceAfterLarge,
	AfterOtherCommit, AfterSiblingFence, TakesFence and AfterStepFence.
	Example usage:
		OneAnswer.AfterOtherCommit(State, Call, Clock, Commands)
--]=]

local AfterAnswer = require("./AfterAnswer")
local Closing = require("../../../Keys/DataStore/Closing")
local Composed = require("../../../Shared/Composed")
local Events = require("../../../Shared/Events")
local JudgingShapes = require("../../../Shared/OpShapes")
local Names = require("../../../Keys/Encoding/Names")
local NextSteps = require("./NextSteps")
local Reasons = require("../../../Keys/Constants/Reasons")
local Replies = require("../../../Shared/Replies")
local Requests = require("./Requests")
local TentReports = require("./TentReports")
local TxCalls = require("./Call")
local TxState = require("../State")

type Command = Events.Command
type GivenAnswer = Events.Answer
type Outcome = Events.Outcome
type StoreKey = Names.StoreKey
type Report = JudgingShapes.Report
type State = Composed.State
type Call = TxState.Call
type OwnMarksStanding = TxState.OwnMarksStanding
type Purpose = TxState.Purpose
type SiblingFence = TxState.SiblingFence

local FenceFor = TxState.FenceFor
local OwnMarksStanding = TxState.OwnMarksStanding

local NoPartFencedYet = 0

local RoutingFault = "OneAnswer: this call is never made."
local NoSiblingFence = `{RoutingFault} A sibling's fence is heard only by a step that sent one.`
local NoSweptPart = `{RoutingFault} A sweep fences only a part its walk would try later.`

local function IsGameStep(Call: Call): boolean
	return Call.IsStep and Call.Name.Kind == "Game" and Call.Name.Part ~= nil
end

local function ServedPartOf(Call: Call): number?
	if not IsGameStep(Call) then
		return nil
	end
	local Served = TentReports.FirstWhere(Call, TentReports.IsServedReport)
	if Served == nil or Served.Kind ~= "Served" then
		return nil
	end
	return Served.Part
end

local function HoldsOwnMark(Call: Call): boolean
	for _, MayHold in Call.MayHoldMark do
		if MayHold then
			return true
		end
	end
	return false
end

local function RecordOwnMarks(Call: Call, Standing: OwnMarksStanding)
	if HoldsOwnMark(Call) then
		Call.OwnMarksStanding = Standing
	end
end

local function SiblingPartOf(Call: Call, Fence: SiblingFence): number
	if Fence.Kind == "Served" then
		return Fence.Part
	end
	local Part = Call.LaterParts[Fence.Position]
	if Part == nil then
		error(NoSweptPart)
	end
	return Part
end

local function SendSiblingFence(State: State, Call: Call, Fence: SiblingFence, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Part = SiblingPartOf(Call, Fence)
	Call.Phase = "SiblingFence"
	local Purpose: Purpose = { Kind = "SiblingFence", CallId = Call.CallId, Key = Requests.SiblingKeyOf(Call, Part) }
	Requests.Issue(State, Call, Requests.SiblingFenceRequest(Call, Part), Purpose, Commands)
end

local function AnswerThenEnd(State: State, Call: Call, Given: GivenAnswer, Clock: number, Commands: { Command })
	TxCalls.Answer(Call, Given, Commands)
	AfterAnswer.EndAnsweredCall(State, Call, Clock, Commands)
end

local function FenceServed(State: State, Call: Call, Part: number, Clock: number, Commands: { Command })
	local Fence: SiblingFence = { Kind = "Served", Part = Part }
	Call.SiblingFence = Fence
	RecordOwnMarks(Call, OwnMarksStanding.OwnPartUnfenced)
	SendSiblingFence(State, Call, Fence, Clock, Commands)
end

local function FenceAfterTents(State: State, Call: Call, Clock: number, Commands: { Command })
	if not IsGameStep(Call) then
		return NextSteps.FenceFinal(State, Call, Clock, Commands)
	end
	if TentReports.FirstWhere(Call, TentReports.IsSweepReport) ~= nil then
		return NextSteps.FenceFinalFor(State, Call, FenceFor.Sweeping, Clock, Commands)
	end
	if TentReports.FirstWhere(Call, TentReports.IsSupersededReport) ~= nil then
		return NextSteps.FenceFinal(State, Call, Clock, Commands)
	end
	NextSteps.FenceFinalFor(State, Call, FenceFor.MovingOn, Clock, Commands)
end

local function FenceAfterLarge(State: State, Call: Call, Clock: number, Commands: { Command })
	if not IsGameStep(Call) then
		return NextSteps.FenceFinal(State, Call, Clock, Commands)
	end
	NextSteps.FenceFinalFor(State, Call, FenceFor.Sweeping, Clock, Commands)
end

local function SweepNext(State: State, Call: Call, Clock: number, Commands: { Command })
	local Fence = Call.SiblingFence
	if Fence == nil or Fence.Kind ~= "Sweep" then
		error(NoSiblingFence)
	end
	Fence.Position += 1
	if Call.LaterParts[Fence.Position] == nil then
		return AnswerThenEnd(State, Call, Replies.FailedAnswer(Reasons.Spent), Clock, Commands)
	end
	SendSiblingFence(State, Call, Fence, Clock, Commands)
end

local function StartSweep(State: State, Call: Call, Clock: number, Commands: { Command })
	RecordOwnMarks(Call, OwnMarksStanding.OwnPartFenced)
	Call.SiblingFence = { Kind = "Sweep", Position = NoPartFencedYet }
	SweepNext(State, Call, Clock, Commands)
end

local function AfterOtherCommit(State: State, Call: Call, Clock: number, Commands: { Command })
	if not IsGameStep(Call) then
		return AfterAnswer.AbortCall(State, Call, Reasons.Spent, Clock, Commands)
	end
	StartSweep(State, Call, Clock, Commands)
end

local function IsFencedOrRefused(Report: Report): boolean
	return Report.Kind == "Fenced" or Report.Kind == "Refused"
end

local function AfterSiblingFence(
	State: State,
	Call: Call,
	Key: StoreKey,
	Result: Outcome,
	Clock: number,
	Commands: { Command }
)
	local Fence = Call.SiblingFence
	if Fence == nil then
		error(NoSiblingFence)
	end
	local Report = Requests.LearnFromAnswer(State, Call, Key, Result, Commands)
	if Report == nil then
		if Requests.IsResendDue(State.Server, Call, Key) then
			return SendSiblingFence(State, Call, Fence, Clock, Commands)
		end
		return AnswerThenEnd(State, Call, Replies.UnresolvedAnswer, Clock, Commands)
	end
	if Report.Kind == "Committed" then
		local Part = SiblingPartOf(Call, Fence)
		return AfterAnswer.AnswerSiblingTook(State, Call, Part, Report.Attempt, Report.DeciderValue, Clock, Commands)
	end
	if Fence.Kind == "Sweep" and IsFencedOrRefused(Report) then
		return SweepNext(State, Call, Clock, Commands)
	end
	AnswerThenEnd(State, Call, Replies.UnresolvedAnswer, Clock, Commands)
end

local function AfterStepFence(State: State, Call: Call, Report: Report, Clock: number, Commands: { Command })
	local SentFor = Call.FenceFor
	if SentFor == FenceFor.Sweeping then
		return StartSweep(State, Call, Clock, Commands)
	end
	if SentFor ~= FenceFor.MovingOn then
		return AfterAnswer.AbortCall(State, Call, Reasons.Unresolved, Clock, Commands)
	end
	if Report.Kind == "Refused" then
		return AfterAnswer.AbortRefused(State, Call, Report, Clock, Commands)
	end
	if Report.Kind == "Fenced" then
		Call.DeciderFate = { Kind = "Fenced" :: "Fenced", Attempt = Report.Attempt, IsFinal = Report.IsFinal }
	end
	AfterAnswer.AbortCall(State, Call, Reasons.Spent, Clock, Commands)
end

local function TakesFence(Call: Call, Report: Report): boolean
	return Call.GivesUp == nil and IsGameStep(Call) and IsFencedOrRefused(Report)
end

return {
	ServedPartOf = ServedPartOf,
	FenceServed = FenceServed,
	FenceAfterTents = FenceAfterTents,
	FenceAfterLarge = FenceAfterLarge,
	AfterOtherCommit = AfterOtherCommit,
	AfterSiblingFence = AfterSiblingFence,
	TakesFence = TakesFence,
	AfterStepFence = AfterStepFence,
}
