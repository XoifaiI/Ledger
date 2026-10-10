--!strict
--!optimize 2

--[=[
	Hearing: a writer's answer in, and each Flush and Refresh; a Flush waits for the push that carries its ops (record
	sheet 10, 11's actions and 13).

	An answer is applied in sheet 10's order. A move to end work leaves the op unheard and starts a help (Tx/Help,
	TX-END); the writer resends after its retry gap and the help.

	Return type: A plain table of functions.
	Example usage:
		local Finished = Hearing.Hear(State, RequestId, Outcome, Clock, Commands)
--]=]

local Adoption = require("../Sessions/Adoption")
local Answering = require("./Answering")
local Answers = require("./Answers")
local Beside = require("../Tx/Beside")
local Cache = require("../Reading/Cache")
local Closing = require("../Sessions/Closing")
local Composed = require("../Composed")
local Events = require("../Events")
local Help = require("../Tx/Work/Help")
local Json = require("../Encoding/Json")
local JudgingShapes = require("../Judging/Shapes")
local KindSetup = require("../Judging/KindSetup")
local Names = require("../Encoding/Names")
local Numbers = require("./Numbers")
local OpForms = require("../Judging/OpForms")
local Reasons = require("../Constants/Reasons")
local Replies = require("../Replies")
local Rides = require("../Tx/Rides")
local Sending = require("./Sending")
local Session = require("../Sessions/Session")
local Shapes = require("../Shapes")
local TxState = require("../Tx/State")
local Value = require("../Stored/Value")
local View = require("../Reading/View")
local Writers = require("./Writer")

type EndWork = Answers.EndWork
type Command = Events.Command
type Outcome = Events.Outcome
type StoreKey = Names.StoreKey
type Finished = Rides.Finished
type Flush = Composed.Flush
type State = Composed.State
type OpMove = Sending.OpMove
type Note = JudgingShapes.Note
type OpenSession = Session.Session
type SentOp = Shapes.SentOp
type UpdateRequest = Shapes.UpdateRequest
type ServerState = Shapes.ServerState
type WriterState = Shapes.WriterState
type Value = Value.Value

type KeyCall = { read CallId: number, read Key: StoreKey }

local NotAnUpdate = "Hearing: this call is never made. A writer's request is always an update."
local StateSizeWarning = "the state has passed %d bytes. A state of %d bytes or more is refused as Full."

local function IsOutWith(Writer: WriterState, RequestId: number): boolean
	if Writer.Out ~= nil and Writer.Out.RequestId == RequestId then
		return true
	end
	return Writer.Final ~= nil and Writer.Final.RequestId == RequestId
end

local function TakeWriterOfRequest(State: State, RequestId: number): WriterState?
	local Out = State.WriterRequests[RequestId]
	if Out == nil then
		return nil
	end
	State.WriterRequests[RequestId] = nil
	local Writer = Cache.StoreNamed(State.Server, Out.Store).Writers[Out.Text]
	if Writer == nil or not IsOutWith(Writer, RequestId) then
		return nil
	end
	return Writer
end

local function UpdateOf(Writer: WriterState, RequestId: number): UpdateRequest
	local Outgoing = Writer.Out
	if Outgoing == nil or Outgoing.RequestId ~= RequestId then
		Outgoing = Writer.Final
	end
	if Outgoing == nil or Outgoing.Request.Kind ~= "Update" then
		error(NotAnUpdate)
	end
	return Outgoing.Request
end

local function SentBy(Writer: WriterState, RequestId: number): { SentOp }
	return UpdateOf(Writer, RequestId).Ops
end

local function IsBehindMove(Moved: OpMove): boolean
	local Move = Moved.Move
	if Move.Kind == "Emit" then
		return Move.Fate.Kind == "Turned" and Move.Fate.Why == Reasons.Behind
	end
	return Move.Kind == "Answer" and Move.Answer.Kind == "Failed" and Move.Answer.Reason == Reasons.Behind
end

local function ApplyMove(
	State: State,
	Writer: WriterState,
	Moved: OpMove,
	Note: Note,
	Clock: number,
	Commands: { Command }
)
	local Op = Moved.Op
	local Move = Moved.Move
	local Open = State.Sessions.Open[Writer.Text]
	if Open ~= nil and IsBehindMove(Moved) then
		Open.IsBehind = true
	end
	if Move.Kind == "Answer" then
		Writers.MarkHeard(Writer, Op)
		Answering.AnswerHeard(State.Server, Commands, Writer.Key, Op, Move.Answer, Moved.Report, Note)
	elseif Move.Kind == "Emit" then
		Writers.MarkHeard(Writer, Op)
		if not Op.IsAnswered then
			Answering.FateOf(Commands, Writer, Op, Move.Fate)
		end
	elseif Move.Kind == "Restamp" then
		Writers.Restamp(Op, Clock, Note.Horizon)
	elseif Move.Kind == "SendAgainWith" then
		Writers.Reincarnate(Op, Move.Identity)
	end
end

local function WarnIfLarge(State: State, Key: StoreKey, Written: Value?, Commands: { Command })
	if Written == nil or Written.Kind ~= "Kept" then
		return
	end
	local Limits = Cache.StoreOf(State.Server, Key).Setup.Limits
	local Entry = Numbers.EntryFor(State.Server, Key)
	if Entry.IsSizeWarned == true or Json.Size(Written.State) <= Limits.StateWarnBytes then
		return
	end
	Entry.IsSizeWarned = true
	local Text = string.format(StateSizeWarning, Limits.StateWarnBytes, Limits.StateCap)
	local Warn: Command = { Kind = "Warn", Key = Key, Text = Text }
	table.insert(Commands, Warn)
end

local function KeepShowableOfWritten(State: State, Key: StoreKey, Written: Value?)
	if Written == nil or Written.Kind ~= "Kept" then
		return
	end
	local Server = State.Server
	local Viewed = View.ViewState(KindSetup.SetupOfKey(Server, Key), Written)
	if Viewed.Kind == "State" then
		local Aborted = TxState.AbortedUses(State.Tx)
		local Entry = Numbers.EntryFor(Server, Key)
		Beside.KeepShowable(Entry, Written, Viewed.State, Server, Key, Aborted, Composed.ServedOf(State))
	end
end

local function ApplyError(
	State: State,
	Writer: WriterState,
	RequestId: number,
	IsBeforeStore: boolean?,
	Clock: number,
	Commands: { Command }
)
	local Limits = Cache.StoreOf(State.Server, Writer.Key).Setup.Limits
	local Sent = SentBy(Writer, RequestId)
	if IsBeforeStore then
		Sending.OnRefusedBeforeStore(State.Server, Writer, RequestId, Sent, Clock, Limits, Commands)
	else
		Sending.OnError(State.Server, Writer, Sent, Clock, Limits, Commands)
	end
	Sending.NoteFinalRetry(Writer, RequestId)
	Sending.AfterAnswer(Writer, RequestId, Clock)
end

local function IsTurnedMove(Moved: OpMove): boolean
	local Move = Moved.Move
	return Move.Kind == "Emit" and Move.Fate.Kind == "Turned"
end

local function ApplyMoves(
	State: State,
	Writer: WriterState,
	RequestId: number,
	Note: Note,
	Clock: number,
	Commands: { Command }
): number
	local Setup = Cache.StoreOf(State.Server, Writer.Key).Setup
	local RoundsBefore = Writer.ErrorsInARow
	local Moves = Sending.OnAnswer(Writer, RequestId, SentBy(Writer, RequestId), Note)
	local Ending: EndWork? = nil
	local Turned = 0
	for _, Moved in Moves do
		ApplyMove(State, Writer, Moved, Note, Clock, Commands)
		if IsTurnedMove(Moved) then
			Turned += 1
		end
		if Ending == nil and Moved.Move.Kind == "EndWork" then
			Ending = Moved.Move
		end
	end
	local LandsAt = Sending.AheadLandsAt(Moves, Setup.Limits)
	if LandsAt ~= nil then
		Sending.PaceAhead(Writer, RoundsBefore, LandsAt, Clock, Setup.Limits)
	end
	if Ending == nil then
		return Turned
	end
	Writer.ErrorsInARow += 1
	Writer.RetryAt = Clock + Sending.RetryGap(Writer.ErrorsInARow, Setup.Limits)
	Sending.NoteFinalRetry(Writer, RequestId)
	Help.EndWork(State, { Kind = "Writer", Key = Writer.Key }, Writer.Key, Ending.Report, Clock, Commands)
	return Turned
end

local function FinishNote(
	State: State,
	Writer: WriterState,
	RequestId: number,
	Note: Note,
	Clock: number,
	Commands: { Command }
): { Finished }
	local Server = State.Server
	local Setup = Cache.StoreOf(Server, Writer.Key).Setup
	local Finished = Rides.Heard(Server, Writer.Key, UpdateOf(Writer, RequestId).Ends, Note)
	Sending.AfterAnswer(Writer, RequestId, Clock)
	Sending.LearnFromNote(Server, Writer, Numbers.EntryFor(Server, Writer.Key), Setup, Note, Commands)
	return Finished
end

local function IsFlushDone(Flush: Flush, Writer: WriterState, RequestId: number): boolean
	if Flush.RequestId ~= nil then
		return Flush.RequestId == RequestId
	end
	return Names.KeyText(Flush.Key) == Names.KeyText(Writer.Key) and Session.IsQuiet(Writer)
end

local function AnswerFlushesOnRequest(State: State, Writer: WriterState, RequestId: number, Commands: { Command })
	local Kept = {}
	for _, Flush in State.Flushing do
		if IsFlushDone(Flush, Writer, RequestId) then
			Replies.Reply(Commands, Flush.CallId, Replies.DoneAnswer)
		else
			table.insert(Kept, Flush)
		end
	end
	State.Flushing = Kept
end

local function AnswerFlushesAtDeadline(State: State, Clock: number, Commands: { Command })
	local Kept = {}
	for _, Flush in State.Flushing do
		if Clock >= Flush.Deadline then
			Replies.Reply(Commands, Flush.CallId, Replies.DoneAnswer)
		else
			table.insert(Kept, Flush)
		end
	end
	State.Flushing = Kept
end

local function AttachFlushes(State: State, Key: StoreKey, RequestId: number)
	local Text = Names.KeyText(Key)
	for _, Flush in State.Flushing do
		if Flush.RequestId == nil and Names.KeyText(Flush.Key) == Text then
			Flush.RequestId = RequestId
		end
	end
end

local function RequestCarryingAll(Writer: WriterState): number?
	local Out = Writer.Out
	if Out == nil or Out.Request.Kind ~= "Update" or #Writer.Waiting > 0 then
		return nil
	end
	local Carried: { [number]: boolean } = {}
	for _, Sent in Out.Request.Ops do
		Carried[OpForms.SequenceOf(Sent.Form)] = true
	end
	for _, Op in Writer.Queue do
		if not Op.IsHeard and not Carried[OpForms.SequenceOf(Op.Form)] then
			return nil
		end
	end
	return Out.RequestId
end

local function Hear(
	State: State,
	RequestId: number,
	Result: Outcome,
	Clock: number,
	Commands: { Command }
): { Finished }
	local Writer = TakeWriterOfRequest(State, RequestId)
	local Finished: { Finished } = {}
	if Writer == nil then
		return Finished
	end
	if Result.Kind == "Err" then
		ApplyError(State, Writer, RequestId, Result.IsBeforeStore, Clock, Commands)
	else
		local Note = Result.Note
		local Turned = ApplyMoves(State, Writer, RequestId, Note, Clock, Commands)
		local IsTaken = false
		if Result.Kind == "Ok" then
			Turned += Adoption.TurnAway(Writer, Note, Commands)
			IsTaken = Adoption.Adopt(State.Server, State.Sessions, Writer, Note, Clock, Commands)
			WarnIfLarge(State, Writer.Key, Note.WrittenValue, Commands)
			KeepShowableOfWritten(State, Writer.Key, Note.WrittenValue)
		end
		if Turned > 0 and not IsTaken then
			Adoption.ShowWithoutTurned(State.Server, State.Sessions, Writer, Clock, Commands)
		end
		Finished = FinishNote(State, Writer, RequestId, Note, Clock, Commands)
	end
	Writers.Renumber(Writer)
	Composed.NoteSendableAt(State, Writer.Text, Writer.Key)
	AnswerFlushesOnRequest(State, Writer, RequestId, Commands)
	Closing.OnReleaseAnswer(State.Sessions, Writer.Key, RequestId, Commands)
	if #State.Server.StepOut == 0 then
		Closing.EndClose(State.Server, State.Sessions, Composed.OpenCount(State), Clock, Commands)
	end
	return Finished
end

local function PushQueued(State: State, Call: KeyCall, Open: OpenSession, Writer: WriterState, Clock: number)
	Open.PushAsked = true
	Composed.NoteSendable(State, Call.Key)
	local Pending: Flush = {
		CallId = Call.CallId,
		Key = Call.Key,
		RequestId = RequestCarryingAll(Writer),
		Deadline = Clock + Cache.StoreOf(State.Server, Call.Key).Setup.Limits.OpBound,
	}
	table.insert(State.Flushing, Pending)
end

local function Flush(State: State, Call: KeyCall, Clock: number, Commands: { Command })
	local Open = State.Sessions.Open[Names.KeyText(Call.Key)]
	local Writer = Writers.WriterFor(State.Server, Call.Key)
	if Open == nil then
		return Replies.ReplyFailed(Commands, Call.CallId, Reasons.Closed)
	end
	if Writer == nil or Session.IsQuiet(Writer) then
		return Replies.Reply(Commands, Call.CallId, Replies.DoneAnswer)
	end
	PushQueued(State, Call, Open, Writer, Clock)
end

local function Refresh(State: State, Call: KeyCall, Clock: number, Commands: { Command })
	local Open = State.Sessions.Open[Names.KeyText(Call.Key)]
	local Writer = Writers.WriterFor(State.Server, Call.Key)
	if Open == nil then
		return Replies.ReplyFailed(Commands, Call.CallId, Reasons.Closed)
	end
	if Writer ~= nil and not Session.IsQuiet(Writer) then
		return PushQueued(State, Call, Open, Writer, Clock)
	end
	local IsAfterEnds = TxState.HasResolveOut(State.Tx, Call.Key)
	Adoption.Refresh(State.Server, State.Sessions, Open, Call.CallId, Clock, IsAfterEnds, Commands)
end

return {
	Hear = Hear,
	Flush = Flush,
	Refresh = Refresh,
	AttachFlushes = AttachFlushes,
	AnswerFlushesAtDeadline = AnswerFlushesAtDeadline,
	WarnIfLarge = WarnIfLarge,
}
