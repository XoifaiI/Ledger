--!strict
--!optimize 2

--[=[
	Outcomes: a Take's outcome, owed by HotState.EndOwedCall once it answered Unresolved with a step, fence or step Tx
	in flight (ruling A1). Its later report settles it once: took is true, an answer is itself, a no or fence moving
	the walk on is Unresolved, as this server walks no further. The ended close settles the rest.

	Return type: A plain table with OnLateStep, OnLateFence, OnLateTxStep and EndOwed.
	Example usage:
		Outcomes.OnLateFence(State, CallId, Result, Commands)
--]=]

local Composed = require("../../Composed")
local Events = require("../../Events")
local JudgingShapes = require("../../Judging/Shapes")
local Reasons = require("../../Constants/Reasons")
local Replies = require("../../Replies")
local Sorted = require("../../Sorted")
local StepAnswer = require("../../Tx/Call/StepAnswer")
local Verdicts = require("./Verdicts")

type Answer = Events.Answer
type Command = Events.Command
type Outcome = Events.Outcome
type Report = JudgingShapes.Report
type Reason = Reasons.Reason
type State = Composed.State
type Verdict = Verdicts.Verdict

local function Settle(State: State, CallId: number, Given: Answer, Commands: { Command })
	local Key = State.Hot.Outcomes[CallId]
	if Key == nil then
		return
	end
	State.Hot.Outcomes[CallId] = nil
	Replies.SettleOutcome(Commands, Key, CallId, Given)
end

local function LateAnswer(Heard: Verdict): Answer
	if Heard.Kind == "Took" then
		return Replies.DoneAnswer
	end
	if Heard.Kind == "Answers" then
		return Heard.Given
	end
	return Replies.UnresolvedAnswer
end

local function OnLateStep(State: State, CallId: number, Reason: Reason?, Report: Report, Commands: { Command })
	if State.Hot.Outcomes[CallId] == nil then
		return
	end
	Settle(State, CallId, LateAnswer(Verdicts.StepVerdict(Reason, Report)), Commands)
end

local function OnLateFence(State: State, CallId: number, Result: Outcome, Commands: { Command })
	if State.Hot.Outcomes[CallId] == nil then
		return
	end
	if Result.Kind == "Err" then
		return Settle(State, CallId, Replies.UnresolvedAnswer, Commands)
	end
	Settle(State, CallId, LateAnswer(Verdicts.FenceVerdict(Result.Note.EndReports[1])), Commands)
end

local function OnLateTxStep(State: State, CallId: number, Taken: StepAnswer.StepAnswer?, Commands: { Command })
	if State.Hot.Outcomes[CallId] == nil then
		return
	end
	if Taken == nil then
		return Settle(State, CallId, Replies.UnresolvedAnswer, Commands)
	end
	Settle(State, CallId, LateAnswer(Verdicts.TxStepVerdict(Taken)), Commands)
end

local function EndOwed(State: State, Commands: { Command })
	for _, CallId in Sorted.SortedIds(State.Hot.Outcomes) do
		Settle(State, CallId, Replies.UnresolvedAnswer, Commands)
	end
end

return {
	OnLateStep = OnLateStep,
	OnLateFence = OnLateFence,
	OnLateTxStep = OnLateTxStep,
	EndOwed = EndOwed,
}
