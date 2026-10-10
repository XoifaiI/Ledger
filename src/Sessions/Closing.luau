--!strict
--!optimize 2

--[=[
	Closing: when a session's writer sends, and how a session and the server end (record sheet 13).

	Release and CloseAll send nothing; their caller sends each final request. EndClose waits for durable ops and
	counted work, warns how many went unheard and settles them: sent Unresolved, unsent Closed. A second CloseAll, a
	later Release and a waiting Refresh answer Closed.

	Return type: A plain table of functions.
	Example usage:
		Closing.CloseAll(State, Sessions, CallId, BeganAt, Commands)
--]=]

local Answering = require("../Writing/Answering")
local Cache = require("../Reading/Cache")
local Events = require("../Events")
local Messages = require("../Constants/Messages")
local Names = require("../Encoding/Names")
local OpForms = require("../Judging/OpForms")
local OpOutcomes = require("../Writing/OpOutcomes")
local Reasons = require("../Constants/Reasons")
local Replies = require("../Replies")
local Sending = require("../Writing/Sending")
local Session = require("./Session")
local Shapes = require("../Shapes")
local Sorted = require("../Sorted")
local Writers = require("../Writing/Writer")

type Answer = Events.Answer
type Command = Events.Command
type StoreKey = Names.StoreKey
type Shutdown = Session.Shutdown
type Session = Session.Session
type SessionState = Session.SessionState
type Releasing = Session.Releasing
type ReleaseCall = Session.ReleaseCall
type Op = Shapes.Op
type Reason = Reasons.Reason
type WriterState = Shapes.WriterState
type ServerState = Shapes.ServerState

local EndedShutdown: Shutdown = table.freeze({ Kind = "Ended" :: "Ended" })
local ClosedAnswer: Answer = table.freeze(Replies.FailedAnswer(Reasons.Closed))

local RoutingFault = "Closing: this call is never made."
local NoSession = `{RoutingFault} Only a key with an open session is released.`

local function ShouldPush(State: ServerState, Open: Session, Clock: number): boolean
	local Store = Cache.StoreOf(State, Open.Key)
	local Writer = Store.Writers[Open.Text]
	if Writer == nil then
		return false
	end
	if Clock - Open.PushedAt < Store.Setup.Limits.SaveInterval then
		return false
	end
	return Sending.MaySend(State, Writer, Clock)
end

local function PushNow(
	State: ServerState,
	Sessions: SessionState,
	Key: StoreKey,
	Clock: number,
	Commands: { Command }
): number?
	local Writer = Writers.WriterFor(State, Key)
	local Open = Sessions.Open[Names.KeyText(Key)]
	if Writer == nil or Open == nil then
		return nil
	end
	Session.FillEntry(State, Open)
	local Pushed = Sending.SendOut(State, Writer, Clock, Commands)
	if Pushed ~= nil then
		Open.PushedAt = Clock
		Open.PushAsked = false
	end
	return Pushed
end

local function WakeAt(Commands: { Command }, At: number)
	local Wake: Command = { Kind = "Wake", At = At }
	table.insert(Commands, Wake)
end

local function Release(
	State: ServerState,
	Sessions: SessionState,
	Call: ReleaseCall,
	Clock: number,
	Commands: { Command }
)
	if Sessions.Shutdown ~= nil then
		return Replies.ReplyFailed(Commands, Call.CallId, Reasons.Closed)
	end
	local Text = Names.KeyText(Call.Key)
	local Open = Sessions.Open[Text]
	if Open == nil then
		error(NoSession)
	end
	Session.FillEntry(State, Open)
	Sessions.Open[Text] = nil
	Session.AnswerEveryRefresh(Sessions, Text, ClosedAnswer, Commands)
	local Writer = Writers.WriterFor(State, Call.Key)
	if Writer == nil or Session.IsQuiet(Writer) then
		return Replies.Reply(Commands, Call.CallId, Replies.DoneAnswer)
	end
	local Deadline = Clock + Cache.StoreOf(State, Call.Key).Setup.Limits.OpBound
	Sessions.Releasing[Text] = { CallId = Call.CallId, Deadline = Deadline }
	WakeAt(Commands, Deadline)
end

local function AttachFinal(Sessions: SessionState, Key: StoreKey, RequestId: number)
	local Text = Names.KeyText(Key)
	local Pending = Sessions.Releasing[Text]
	if Pending ~= nil and Pending.RequestId == nil then
		Sessions.Releasing[Text] = { CallId = Pending.CallId, RequestId = RequestId, Deadline = Pending.Deadline }
	end
end

local function OnReleaseAnswer(Sessions: SessionState, Key: StoreKey, RequestId: number, Commands: { Command })
	local Text = Names.KeyText(Key)
	local Pending = Sessions.Releasing[Text]
	if Pending == nil or Pending.RequestId ~= RequestId then
		return
	end
	Sessions.Releasing[Text] = nil
	Replies.Reply(Commands, Pending.CallId, Replies.DoneAnswer)
end

local function ReleaseTimeOut(Sessions: SessionState, Clock: number, Commands: { Command })
	local function IsDue(Pending: Releasing): boolean
		return Clock >= Pending.Deadline
	end
	for _, Text in Sorted.SortedDueTexts(Sessions.Releasing, IsDue) do
		Replies.Reply(Commands, Sessions.Releasing[Text].CallId, Replies.DoneAnswer)
		Sessions.Releasing[Text] = nil
	end
end

local function ShutdownDeadline(State: ServerState, Clock: number): number?
	local Deadline: number? = nil
	for _, Store in State.Stores do
		local Limits = Store.Setup.Limits
		local Ends = Clock + Limits.ShutdownSeconds - Limits.Jump
		if Deadline == nil or Ends < Deadline then
			Deadline = Ends
		end
	end
	return Deadline
end

local function CloseAll(
	State: ServerState,
	Sessions: SessionState,
	CallId: number,
	BeganAt: number,
	Commands: { Command }
)
	if Sessions.Shutdown ~= nil then
		return Replies.ReplyFailed(Commands, CallId, Reasons.Closed)
	end
	local Deadline = ShutdownDeadline(State, BeganAt)
	if Deadline == nil then
		Sessions.Shutdown = EndedShutdown
		return Replies.Reply(Commands, CallId, Replies.DoneAnswer)
	end
	Sessions.Shutdown = { Kind = "Ending", CallId = CallId, Deadline = Deadline }
	for _, Text in Sorted.SortedTexts(Sessions.Open) do
		Session.FillEntry(State, Sessions.Open[Text])
		Sessions.Open[Text] = nil
		Session.AnswerEveryRefresh(Sessions, Text, ClosedAnswer, Commands)
	end
	WakeAt(Commands, Deadline)
end

local function ServerUnheardCount(State: ServerState): number
	local Count = 0
	for _, Store in State.Stores do
		for _, Writer in Store.Writers do
			Count += Writers.UnheardCount(Writer)
		end
	end
	return Count
end

local function ReasonOfUnheard(Op: Op): Reason
	if Op.IsSent then
		return Reasons.Unresolved
	end
	return Reasons.Closed
end

local function AnswerUnheardCalls(State: ServerState, Commands: { Command })
	for _, Name in Sorted.SortedTexts(State.Stores) do
		local Store = State.Stores[Name]
		for _, Text in Sorted.SortedTexts(Store.Writers) do
			local Writer = Store.Writers[Text]
			for _, Op in Writer.Queue do
				if not Op.IsHeard and OpForms.IsDurable(Op.Form) then
					Answering.AnswerCallFailed(State, Commands, Op, ReasonOfUnheard(Op))
					OpOutcomes.Stop(State, Commands, Writer.Key, Op)
				end
			end
			local KeptWaiting = {}
			for _, Waiting in Writer.Waiting do
				if Waiting.Form.Kind == "Hopeful" then
					table.insert(KeptWaiting, Waiting)
				else
					Answering.AnswerWaitingFailed(State, Commands, Writer.Key, Waiting, Reasons.Closed)
				end
			end
			Writer.Waiting = KeptWaiting
		end
	end
end

local function IsEnded(Sessions: SessionState): boolean
	local Shutdown = Sessions.Shutdown
	return Shutdown ~= nil and Shutdown.Kind == "Ended"
end

local function IsPastDeadline(Sessions: SessionState, Clock: number): boolean
	local Shutdown = Sessions.Shutdown
	if Shutdown == nil then
		return false
	end
	return Shutdown.Kind == "Ended" or Clock >= Shutdown.Deadline
end

local function EndClose(
	State: ServerState,
	Sessions: SessionState,
	OpenOthers: number,
	Clock: number,
	Commands: { Command }
)
	local Shutdown = Sessions.Shutdown
	if Shutdown == nil or Shutdown.Kind ~= "Ending" then
		return
	end
	local Unheard = ServerUnheardCount(State)
	local NotHeard = Unheard + OpenOthers
	if NotHeard > 0 and Clock < Shutdown.Deadline then
		return
	end
	if Unheard > 0 then
		AnswerUnheardCalls(State, Commands)
	end
	if NotHeard > 0 then
		local Warn: Command = { Kind = "Warn", Key = nil, Text = Messages.OpsUnheard(NotHeard) }
		table.insert(Commands, Warn)
	end
	Replies.Reply(Commands, Shutdown.CallId, Replies.DoneAnswer)
	Sessions.Shutdown = EndedShutdown
end

return {
	ShouldPush = ShouldPush,
	PushNow = PushNow,
	Release = Release,
	AttachFinal = AttachFinal,
	OnReleaseAnswer = OnReleaseAnswer,
	ReleaseTimeOut = ReleaseTimeOut,
	ShutdownDeadline = ShutdownDeadline,
	CloseAll = CloseAll,
	EndClose = EndClose,
	IsEnded = IsEnded,
	IsPastDeadline = IsPastDeadline,
}
