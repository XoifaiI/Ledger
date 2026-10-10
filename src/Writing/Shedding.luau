--!strict
--!optimize 2

--[=[
	Shedding: when a writer's ops are shed or timed out (record sheet 7, K5, L1). An unsent durable op is
	shed Busy at Qwait - Jump from its queue start; a sent one answers Unresolved at B_op. On a paced writer the
	queue start is when the gap lets the op go, and B_op counts from its first send.

	Return type: A plain table of functions.
	Example usage:
		Shedding.ShedUnsent(State, Writer, Clock, Limits, Commands)
--]=]

local Answering = require("./Answering")
local Cache = require("../Reading/Cache")
local Events = require("../Events")
local OpForms = require("../Judging/OpForms")
local Pacing = require("./Pacing")
local Reasons = require("../Constants/Reasons")
local Shapes = require("../Shapes")
local Writers = require("./Writer")

type Command = Events.Command
type Limits = Shapes.Limits
type Op = Shapes.Op
type ServerState = Shapes.ServerState
type WaitingOp = Shapes.WaitingOp
type WriterState = Shapes.WriterState

local IsDurable = OpForms.IsDurable

local function QueueDeadline(Start: number, Limits: Limits): number
	return Start + Limits.QueueWait - Limits.Jump
end

local function StoreQueueDeadline(Server: ServerState, Store: string, Arrived: number): number
	return QueueDeadline(Arrived, Cache.StoreNamed(Server, Store).Setup.Limits)
end

local function GapEndStart(Writer: WriterState, JoinedAt: number): number
	local Paced = Writer.Paced
	if Paced == nil then
		return JoinedAt
	end
	return math.max(JoinedAt, Pacing.NextSendAt(Paced))
end

local function OpDeadline(Writer: WriterState, Op: Op, Limits: Limits): number
	local PassedAt = Op.SentOrPassedAt
	if Writer.Paced == nil or PassedAt == nil then
		return QueueDeadline(GapEndStart(Writer, Op.JoinedAt), Limits)
	end
	return QueueDeadline(PassedAt, Limits)
end

local function WaitingDeadline(Writer: WriterState, Waiting: WaitingOp, Limits: Limits): number
	return QueueDeadline(GapEndStart(Writer, Waiting.JoinedAt), Limits)
end

local function OpBoundAt(Writer: WriterState, Op: Op, Limits: Limits): number
	local PassedAt = Op.SentOrPassedAt
	if Writer.Paced == nil or PassedAt == nil then
		return Op.JoinedAt + Limits.OpBound
	end
	return PassedAt + Limits.OpBound
end

local function IsOpPastDeadline(Writer: WriterState, Op: Op, Clock: number, Limits: Limits): boolean
	local IsUnsent = not Op.IsSent and not Op.IsHeard
	return IsUnsent and IsDurable(Op.Form) and Clock >= OpDeadline(Writer, Op, Limits)
end

local function IsWaitingPastDeadline(Writer: WriterState, Waiting: WaitingOp, Clock: number, Limits: Limits): boolean
	return Waiting.Form.Kind ~= "Hopeful" and Clock >= WaitingDeadline(Writer, Waiting, Limits)
end

local function HasPastDeadline(Writer: WriterState, Clock: number, Limits: Limits): boolean
	for _, Op in Writer.Queue do
		if IsOpPastDeadline(Writer, Op, Clock, Limits) then
			return true
		end
	end
	for _, Waiting in Writer.Waiting do
		if IsWaitingPastDeadline(Writer, Waiting, Clock, Limits) then
			return true
		end
	end
	return false
end

local function DropPastDeadline(
	State: ServerState,
	Writer: WriterState,
	Clock: number,
	Limits: Limits,
	Commands: { Command }
)
	local KeptQueue = {}
	for _, Op in Writer.Queue do
		if IsOpPastDeadline(Writer, Op, Clock, Limits) then
			Writers.NoteNotTook(Writer, Op)
			Answering.AnswerCallFailed(State, Commands, Op, Reasons.Busy)
		else
			table.insert(KeptQueue, Op)
		end
	end
	Writer.Queue = KeptQueue
	local KeptWaiting = {}
	for _, Waiting in Writer.Waiting do
		if IsWaitingPastDeadline(Writer, Waiting, Clock, Limits) then
			Answering.AnswerWaitingFailed(State, Commands, Writer.Key, Waiting, Reasons.Busy)
		else
			table.insert(KeptWaiting, Waiting)
		end
	end
	Writer.Waiting = KeptWaiting
end

local function ShedUnsent(State: ServerState, Writer: WriterState, Clock: number, Limits: Limits, Commands: { Command })
	if HasPastDeadline(Writer, Clock, Limits) then
		DropPastDeadline(State, Writer, Clock, Limits, Commands)
	end
	Writers.PruneHeard(Writer, Clock)
end

local function IsOpTimedOut(Writer: WriterState, Op: Op, Clock: number, Limits: Limits): boolean
	return Op.IsSent and IsDurable(Op.Form) and Clock >= OpBoundAt(Writer, Op, Limits)
end

local function HasTimedOut(Writer: WriterState, Clock: number, Limits: Limits): boolean
	for _, Op in Writer.Queue do
		if IsOpTimedOut(Writer, Op, Clock, Limits) then
			return true
		end
	end
	return false
end

local function TimeOut(State: ServerState, Writer: WriterState, Clock: number, Limits: Limits, Commands: { Command })
	for _, Op in Writer.Queue do
		if IsOpTimedOut(Writer, Op, Clock, Limits) then
			Writers.NoteNotTook(Writer, Op)
			Answering.AnswerCallFailed(State, Commands, Op, Reasons.Unresolved)
		end
	end
end

return {
	QueueDeadline = QueueDeadline,
	StoreQueueDeadline = StoreQueueDeadline,
	OpDeadline = OpDeadline,
	WaitingDeadline = WaitingDeadline,
	OpBoundAt = OpBoundAt,
	HasPastDeadline = HasPastDeadline,
	HasTimedOut = HasTimedOut,
	ShedUnsent = ShedUnsent,
	TimeOut = TimeOut,
}
