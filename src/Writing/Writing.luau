--!strict
--!optimize 2

--[=[
	Writing: a writer's request out (record sheet 7 case 3, 6 and 13).

	A writer never sends inside the event that made it free to: step says Ready, and the shell answers Send. The key's
	incarnation is read before the first send, again after a failed read while an op needs it, and an unreadable value
	fails every unsent op.

	Return type: A plain table of functions.
	Example usage:
		Writing.ReadySendable(State, Clock, Commands)
		Writing.SendOnEvent(State, Key, Clock, Commands)
--]=]

local Answering = require("./Answering")
local Answers = require("./Answers")
local Cache = require("../Reading/Cache")
local Closing = require("../Sessions/Closing")
local Composed = require("../Composed")
local Events = require("../Events")
local Hearing = require("./Hearing")
local Incarnations = require("./Incarnations")
local Names = require("../Encoding/Names")
local Numbers = require("./Numbers")
local OpForms = require("../Judging/OpForms")
local Sending = require("./Sending")
local Session = require("../Sessions/Session")
local Shapes = require("../Shapes")
local Sorted = require("../Sorted")
local Unreadable = require("../Reading/Unreadable")
local Value = require("../Stored/Value")
local Writers = require("./Writer")

type Command = Events.Command
type ReadOutcome = Events.ReadOutcome
type StoreKey = Names.StoreKey
type IncarnationRead = Composed.IncarnationRead
type State = Composed.State
type Limits = Shapes.Limits
type WriterState = Shapes.WriterState
type UnreadableCause = Value.UnreadableCause

local function IssueRead(State: State, Text: string, Reading: IncarnationRead, Commands: { Command })
	local RequestId = Numbers.NewRequestId(State.Server)
	Reading.RequestId = RequestId
	Reading.RetryAt = nil
	State.IncarnationReads[RequestId] = Text
	local Get: Command = { Kind = "Get", RequestId = RequestId, Target = Reading.Key }
	table.insert(Commands, Get)
end

local function ReadIncarnation(State: State, Writer: WriterState, Commands: { Command })
	local Text = Writer.Text
	if State.Incarnations[Text] ~= nil then
		return
	end
	local Reading: IncarnationRead = { Key = Writer.Key, ErrorsInARow = 0 }
	State.Incarnations[Text] = Reading
	IssueRead(State, Text, Reading, Commands)
end

local function OwesFinal(State: State, Writer: WriterState): boolean
	local Ending = State.Sessions.Shutdown
	if Ending ~= nil then
		return Ending.Kind == "Ending"
	end
	local Pending = State.Sessions.Releasing[Writer.Text]
	return Pending ~= nil and Pending.RequestId == nil
end

local function NoteRequestOut(State: State, Writer: WriterState, RequestId: number?)
	if RequestId ~= nil then
		State.WriterRequests[RequestId] = { Store = Writer.Key.Store, Text = Writer.Text }
	end
end

local function SendFinalRequest(State: State, Writer: WriterState, Clock: number, Commands: { Command })
	local RequestId = Sending.SendFinal(State.Server, Writer, Clock, Commands)
	NoteRequestOut(State, Writer, RequestId)
	if RequestId ~= nil then
		Closing.AttachFinal(State.Sessions, Writer.Key, RequestId)
	end
end

local function Send(State: State, Writer: WriterState, Clock: number, Commands: { Command })
	local Server = State.Server
	local Open = State.Sessions.Open[Writer.Text]
	if Open ~= nil then
		Session.FillEntry(Server, Open)
	end
	if Incarnations.NeedsIncarnation(Server, Writer) then
		if Closing.IsPastDeadline(State.Sessions, Clock) then
			return
		end
		return ReadIncarnation(State, Writer, Commands)
	end
	if OwesFinal(State, Writer) and not Closing.IsPastDeadline(State.Sessions, Clock) then
		return SendFinalRequest(State, Writer, Clock, Commands)
	end
	if State.Sessions.Shutdown ~= nil then
		return
	end
	if Open == nil then
		NoteRequestOut(State, Writer, Sending.SendOut(Server, Writer, Clock, Commands))
		return
	end
	local Pushed = Closing.PushNow(Server, State.Sessions, Writer.Key, Clock, Commands)
	NoteRequestOut(State, Writer, Pushed)
	if Pushed ~= nil then
		Hearing.AttachFlushes(State, Writer.Key, Pushed)
	end
end

local function SendOnEvent(State: State, Key: StoreKey, Clock: number, Commands: { Command })
	local Writer = Writers.WriterFor(State.Server, Key)
	if Writer ~= nil then
		Composed.NoteTimersMovedAt(State, Writer.Text, Key)
		Send(State, Writer, Clock, Commands)
	end
end

local function HasUnheardDurable(Writer: WriterState): boolean
	for _, Op in Writer.Queue do
		if not Op.IsHeard and OpForms.IsDurable(Op.Form) then
			return true
		end
	end
	return false
end

local function SendsOnItsOwn(State: State, Writer: WriterState, Clock: number): boolean
	if OwesFinal(State, Writer) then
		return true
	end
	local Open = State.Sessions.Open[Writer.Text]
	if Open == nil then
		return true
	end
	if Open.PushAsked or Closing.ShouldPush(State.Server, Open, Clock) then
		return true
	end
	return HasUnheardDurable(Writer)
end

local function MaySendNow(State: State, Writer: WriterState, Clock: number): boolean
	local Server = State.Server
	if Incarnations.NeedsIncarnation(Server, Writer) then
		return State.Incarnations[Writer.Text] == nil
	end
	if OwesFinal(State, Writer) then
		return Sending.MaySendFinal(Server, Writer, Clock)
	end
	return Sending.MaySend(Server, Writer, Clock)
end

local function ReadySendable(State: State, Clock: number, Commands: { Command })
	local Sendable = State.Sendable
	State.Sendable = {}
	for _, Text in Sorted.SortedTexts(Sendable) do
		local Key = Sendable[Text]
		local Writer = Cache.StoreOf(State.Server, Key).Writers[Text]
		if Writer == nil or not SendsOnItsOwn(State, Writer, Clock) or not MaySendNow(State, Writer, Clock) then
			continue
		end
		local Ready: Command = { Kind = "Ready", Key = Key }
		table.insert(Commands, Ready)
	end
end

local function RetryRead(Reading: IncarnationRead, Limits: Limits, Clock: number)
	Reading.ErrorsInARow += 1
	Reading.RequestId = nil
	Reading.RetryAt = Clock + Sending.RetryGap(Reading.ErrorsInARow, Limits)
end

local function TurnAwayUnsent(
	State: State,
	Writer: WriterState,
	Cause: UnreadableCause,
	Clock: number,
	Commands: { Command }
)
	for _, Op in Writer.Queue do
		if Op.IsHeard or Op.IsSent then
			continue
		end
		Writers.MarkHeard(Writer, Op)
		if Op.Form.Kind ~= "Hopeful" then
			Writers.NoteNotTook(Writer, Op)
			Answering.AnswerCallFailed(State.Server, Commands, Op, Unreadable.ReasonOf(Cause))
		elseif not Op.IsAnswered then
			Writers.NoteTurnedAway(Writer, Op)
			Answering.FateOf(Commands, Writer, Op, Answers.UnreadableFate(Cause))
		end
	end
	Writers.PruneHeard(Writer, Clock)
end

local function LearnIncarnation(
	State: State,
	RequestId: number,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
)
	local Text = State.IncarnationReads[RequestId]
	if Text == nil then
		return
	end
	State.IncarnationReads[RequestId] = nil
	local Reading = State.Incarnations[Text]
	if Reading == nil or Reading.RequestId ~= RequestId then
		return
	end
	local Setup = Cache.StoreOf(State.Server, Reading.Key).Setup
	if Fetched.Kind == "Failed" then
		return RetryRead(Reading, Setup.Limits, Clock)
	end
	local Read = Numbers.LearnStored(State.Server, Reading.Key, Setup, Fetched, Clock)
	State.Incarnations[Text] = nil
	local Writer = Writers.WriterFor(State.Server, Reading.Key)
	if Read.Kind == "Unreadable" and Writer ~= nil then
		Unreadable.Warn(State.Server, Reading.Key, Read.Cause, Commands)
		TurnAwayUnsent(State, Writer, Read.Cause, Clock, Commands)
	end
	return Composed.NoteSendableAt(State, Text, Reading.Key)
end

local function IsStillNeeded(State: State, Key: StoreKey): boolean
	local Writer = Writers.WriterFor(State.Server, Key)
	return Writer ~= nil and Incarnations.NeedsIncarnation(State.Server, Writer)
end

local function RetryReads(State: State, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local function IsDue(Reading: IncarnationRead): boolean
		return Composed.IsReached(Reading.RetryAt, Clock)
	end
	for _, Text in Sorted.SortedDueTexts(State.Incarnations, IsDue) do
		local Reading = State.Incarnations[Text]
		if IsStillNeeded(State, Reading.Key) then
			IssueRead(State, Text, Reading, Commands)
		else
			State.Incarnations[Text] = nil
		end
	end
end

return {
	SendOnEvent = SendOnEvent,
	ReadySendable = ReadySendable,
	LearnIncarnation = LearnIncarnation,
	RetryReads = RetryReads,
}
