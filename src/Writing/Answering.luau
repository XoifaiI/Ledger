--!strict
--!optimize 2

--[=[
	Answering: how a writer op's call is answered, once (record sheet 10). A step op's answers go to StepOut, a hopeful
	op's fate to the Fate stream, any other answer to its call. A session's Commit answers true with the state of the
	note that told it. An answer heard after the call was answered goes to OpOutcomes.

	Return type: A plain table with AnswerWaitingFailed, AnswerCallFailed, AnswerHeard and FateOf.
	Example usage:
		Answering.AnswerCallFailed(State, Commands, Op, Reasons.Busy)
--]=]

local Answers = require("./Answers")
local Events = require("../Events")
local JudgingShapes = require("../Judging/Shapes")
local Names = require("../Encoding/Names")
local OpOutcomes = require("./OpOutcomes")
local Reasons = require("../Constants/Reasons")
local Replies = require("../Replies")
local Shapes = require("../Shapes")

type Answer = Events.Answer
type Command = Events.Command
type FateEmission = Answers.FateEmission
type Emitted = Answers.Emitted
type Caller = { read CallId: number?, read IsStep: boolean }
type StoreKey = Names.StoreKey
type Reason = Reasons.Reason
type Report = JudgingShapes.Report
type Note = JudgingShapes.Note
type StepOut = Shapes.StepOut
type WaitingOp = Shapes.WaitingOp
type Op = Shapes.Op
type WriterState = Shapes.WriterState
type ServerState = Shapes.ServerState

local FateStream = "Fate"

local RoutingFault = "Answering: this call is never made."
local NoCallToFate = `{RoutingFault} A hopeful op always carries the call that applied it.`

local function SendAnswer(Commands: { Command }, Asker: Caller, Answer: Answer)
	if Asker.CallId ~= nil then
		Replies.Reply(Commands, Asker.CallId, Answer)
	end
end

local function ClaimAnswer(Op: Op): boolean
	if Op.IsAnswered then
		return false
	end
	Op.IsAnswered = true
	return true
end

local function RouteFailed(State: ServerState, Commands: { Command }, Asker: Caller, Reason: Reason)
	if Asker.CallId == nil then
		return
	end
	if Asker.IsStep then
		local Out: StepOut = { Kind = "Answered", CallId = Asker.CallId, Reason = Reason }
		table.insert(State.StepOut, Out)
		return
	end
	SendAnswer(Commands, Asker, Replies.FailedAnswer(Reason))
end

local function AnswerWaitingFailed(
	State: ServerState,
	Commands: { Command },
	Key: StoreKey,
	Waiting: WaitingOp,
	Reason: Reason
)
	RouteFailed(State, Commands, Waiting, Reason)
	OpOutcomes.SettleOnLeaving(Commands, Key, Waiting, Reason)
end

local function AnswerCallFailed(State: ServerState, Commands: { Command }, Op: Op, Reason: Reason)
	if ClaimAnswer(Op) then
		Op.OwesOutcome = OpOutcomes.Owes(Op, Reason)
		RouteFailed(State, Commands, Op, Reason)
	end
end

local function HeardAnswer(Op: Op, Answer: Answer, Note: Note): Answer
	if Op.GivesState and Answer.Kind == "Succeeded" then
		return { Kind = "Succeeded", Value = Note.State }
	end
	return Answer
end

local function AnswerHeard(
	State: ServerState,
	Commands: { Command },
	Key: StoreKey,
	Op: Op,
	Answer: Answer,
	Report: Report,
	Note: Note
)
	local Heard = HeardAnswer(Op, Answer, Note)
	if not ClaimAnswer(Op) then
		return OpOutcomes.HearLate(State, Commands, Key, Op, Heard, Report)
	end
	local Reason = if Answer.Kind == "Failed" then Answer.Reason else nil
	if Op.IsStep and Op.CallId ~= nil then
		local Out: StepOut = { Kind = "Heard", CallId = Op.CallId, Reason = Reason, Report = Report, Note = Note }
		table.insert(State.StepOut, Out)
		return
	end
	SendAnswer(Commands, Op, Heard)
	OpOutcomes.SettleOnLeaving(Commands, Key, Op, Reason)
end

local function FateOf(Commands: { Command }, Writer: WriterState, Op: Op, Emitted: Emitted)
	if Op.CallId == nil then
		error(NoCallToFate)
	end
	Op.IsAnswered = true
	local Emission: FateEmission = { CallId = Op.CallId, Fate = Emitted, OpKind = Op.OpKind, Terms = Op.Terms }
	local EmitCommand: Command = { Kind = "Emit", Stream = FateStream, Key = Writer.Key, Value = Emission }
	table.insert(Commands, EmitCommand)
end

return {
	AnswerWaitingFailed = AnswerWaitingFailed,
	AnswerCallFailed = AnswerCallFailed,
	AnswerHeard = AnswerHeard,
	FateOf = FateOf,
}
