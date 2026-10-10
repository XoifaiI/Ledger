--!strict
--!optimize 2

--[=[
	Sending: a writer's requests and answers (record sheets 7, 8, 10).

	An op is clean once its requests answered. An undecided clean op takes its id sharer's tag. A tidy owed sends no
	op. A final skips the retry gap until an err or mark. An op heard ahead waits to land (PaceAhead). A refusal before
	the store sheds clean durable ops Busy, settling an owed Outcome.

	Return type: A plain table of functions, and the OpMove type.
	Example usage:
		local Request = Sending.BuildRequest(State, KeyWriter, Clock)
--]=]

local Answering = require("./Answering")
local Answers = require("./Answers")
local Book = require("../Stored/Book")
local Cache = require("../Reading/Cache")
local Entries = require("../Stored/Entries")
local Events = require("../Events")
local Incarnations = require("./Incarnations")
local JudgingShapes = require("../Judging/Shapes")
local Names = require("../Encoding/Names")
local Numbers = require("./Numbers")
local OpForms = require("../Judging/OpForms")
local OpOutcomes = require("./OpOutcomes")
local Pacing = require("./Pacing")
local Reasons = require("../Constants/Reasons")
local Rides = require("../Tx/Rides")
local Shapes = require("../Shapes")
local Unreadable = require("../Reading/Unreadable")
local Writers = require("./Writer")

type Command = Events.Command
type Identity = Book.Identity
type Name = Names.Name
type StoreKey = Names.StoreKey
type DurableMove = Answers.DurableMove
type HopefulMove = Answers.HopefulMove
type Limits = Shapes.Limits
type Setup = Shapes.Setup
type Incarnation = Shapes.Incarnation
type Op = Shapes.Op
type SentOp = Shapes.SentOp
type Request = Shapes.Request
type Report = JudgingShapes.Report
type Note = JudgingShapes.Note
type CacheEntry = Shapes.CacheEntry
type Outgoing = Shapes.Outgoing
type WriterState = Shapes.WriterState
type ServerState = Shapes.ServerState

type Move = DurableMove | HopefulMove

export type OpMove = {
	Op: Op,
	Move: Move,
	Report: Report,
}

type KeyIdHeard = { read Carried: Incarnation?, read Identity: Identity? }

local NoEpoch = 0
local RetryGapGrowth = 2

local UndecidedReport: Report = table.freeze({ Kind = "Undecided" :: "Undecided" })

local RoutingFault = "Sending: this call is never made."
local UnqueuedOpAnswered = `{RoutingFault} A cut, a Tent or a Commit is never queued, so no report is given for one.`
local NeverSentCarried = `{RoutingFault} An op that no request carried has no report.`
local AlsoCutWarning = "the name %s is also a cut in progress. The call that used it may be refused."
local CreatedAfterEraseWarning =
	"a resent call made the key again after it was erased. The call should have been refused."

local function HasUnheard(Writer: WriterState): boolean
	for _, Op in Writer.Queue do
		if not Op.IsHeard then
			return true
		end
	end
	return false
end

local function MaySend(State: ServerState, Writer: WriterState, Clock: number): boolean
	if State.ServerNumber == nil or Writer.Out ~= nil or Writer.Final ~= nil or Writer.HelpId ~= nil then
		return false
	end
	if Incarnations.NeedsIncarnation(State, Writer) then
		return false
	end
	local RetryAt = Writer.RetryAt
	if RetryAt ~= nil and Clock < RetryAt then
		return false
	end
	if Writer.Paced ~= nil and not Pacing.MaySend(Writer.Paced, Clock) then
		return false
	end
	return HasUnheard(Writer) or Writer.TidyOwed
end

local function MaySendFinal(State: ServerState, Writer: WriterState, Clock: number): boolean
	if
		State.ServerNumber == nil
		or Writer.Final ~= nil
		or Writer.HelpId ~= nil
		or Incarnations.NeedsIncarnation(State, Writer)
	then
		return false
	end
	local RetryAt = Writer.RetryAt
	if Writer.FinalWaitsRetry and RetryAt ~= nil and Clock < RetryAt then
		return false
	end
	return HasUnheard(Writer)
end

local function StampFor(Op: Op, Clock: number, CachedHorizon: number?): number
	if Op.Stamp ~= nil then
		return Op.Stamp
	end
	if CachedHorizon == nil then
		return Clock
	end
	return math.max(Clock, CachedHorizon + 1)
end

local function NewTimedBytes(Op: Op, Limits: Limits): number
	if Op.Form.Kind ~= "Timed" then
		return 0
	end
	local Widest = Entries.NewTimedEntry(Limits, Op.OpKind, Op.Form.Name, Limits.StampMax, { Kind = "Took" })
	return Limits.ItemSize(Book.Rooms.Timed, Widest, NoEpoch, Limits.WindowUnit)
end

local function AddCarried(Sequences: { [number]: boolean }, Outgoing: Outgoing?)
	if Outgoing == nil or Outgoing.Request.Kind ~= "Update" then
		return
	end
	for _, Carried in Outgoing.Request.Ops do
		Sequences[OpForms.SequenceOf(Carried.Form)] = true
	end
end

local function IsOtherRequest(Outgoing: Outgoing?, AnsweredId: number): boolean
	return Outgoing ~= nil and Outgoing.RequestId ~= AnsweredId
end

local function SequencesOut(Writer: WriterState): { [number]: boolean }
	local Sequences = {}
	AddCarried(Sequences, Writer.Out)
	AddCarried(Sequences, Writer.Final)
	return Sequences
end

local function SequencesCarriedElsewhere(Writer: WriterState, AnsweredId: number): { [number]: boolean }
	local Sequences = {}
	if IsOtherRequest(Writer.Out, AnsweredId) then
		AddCarried(Sequences, Writer.Out)
	end
	if IsOtherRequest(Writer.Final, AnsweredId) then
		AddCarried(Sequences, Writer.Final)
	end
	return Sequences
end

local function BuildRequest(State: ServerState, Writer: WriterState, Clock: number): Request
	Writer.TidyOwed = false
	local Setup = Cache.StoreOf(State, Writer.Key).Setup
	local Limits = Setup.Limits
	local Entry = Cache.FindEntry(State, Writer.Key)
	local Horizon = nil
	if Entry ~= nil then
		Horizon = Entry.Horizon
	end
	local Elsewhere = SequencesOut(Writer)
	local NewBytes = 0
	local SentOps: { SentOp } = {}
	local FirstMustExist = false
	local FirstSent: Incarnation? = nil
	for _, Op in Writer.Queue do
		if Op.IsHeard then
			continue
		end
		local Bytes = NewTimedBytes(Op, Limits)
		if #SentOps > 0 and NewBytes + Bytes > Limits.NewTimedBytesMax then
			break
		end
		NewBytes += Bytes
		local Stamped = StampFor(Op, Clock, Horizon)
		Op.Stamp = Stamped
		local OpIncarnation = Incarnations.IncarnationFor(State, Setup, Writer.Key, Op, FirstSent)
		if Op.Incarnation == nil then
			FirstSent = OpIncarnation
		end
		Op.Incarnation = OpIncarnation
		Op.IsSent = true
		if #SentOps == 0 then
			FirstMustExist = Op.MustExist
		end
		local SentOp: SentOp = {
			Form = Op.Form,
			OpKind = Op.OpKind,
			Terms = Op.Terms,
			Stamp = Stamped,
			Incarnation = OpIncarnation,
			IsClean = Op.IsClean and not Elsewhere[OpForms.SequenceOf(Op.Form)],
		}
		table.insert(SentOps, SentOp)
	end
	return {
		Kind = "Update",
		WriterId = Writer.WriterId,
		Acknowledged = Writer.Acknowledged,
		MustExist = FirstMustExist,
		Ops = SentOps,
		Ends = Rides.TakeFor(State, Writer.Key, Clock, { Kind = "Writer", Key = Writer.Key }),
	}
end

local function MarkSendPassed(Writer: WriterState, Clock: number)
	for _, Op in Writer.Queue do
		if not Op.IsHeard and Op.SentOrPassedAt == nil then
			Op.SentOrPassedAt = Clock
		end
	end
end

local function Send(State: ServerState, Writer: WriterState, Clock: number, Commands: { Command }): Outgoing
	local Built = BuildRequest(State, Writer, Clock)
	MarkSendPassed(Writer, Clock)
	if Writer.Paced ~= nil then
		Pacing.NoteSend(Writer.Paced, Clock)
	end
	local Sent: Outgoing = { RequestId = Numbers.NewRequestId(State), Request = Built }
	local Update: Command = { Kind = "Update", RequestId = Sent.RequestId, Target = Writer.Key, Request = Built }
	table.insert(Commands, Update)
	return Sent
end

local function SendOut(State: ServerState, Writer: WriterState, Clock: number, Commands: { Command }): number?
	if not MaySend(State, Writer, Clock) then
		return nil
	end
	local Sent = Send(State, Writer, Clock, Commands)
	Writer.Out = Sent
	return Sent.RequestId
end

local function SendFinal(State: ServerState, Writer: WriterState, Clock: number, Commands: { Command }): number?
	if not MaySendFinal(State, Writer, Clock) then
		return nil
	end
	local Sent = Send(State, Writer, Clock, Commands)
	Writer.Final = Sent
	return Sent.RequestId
end

local function RetryGap(ErrorsInARow: number, Limits: Limits): number
	return math.min(Limits.RetryGapFirst * RetryGapGrowth ^ (ErrorsInARow - 1), Limits.RetryGapMost)
end

local function CountError(State: ServerState, Writer: WriterState, Found: Op, Limits: Limits, Commands: { Command })
	Found.IsClean = false
	Found.ErrorsInARow += 1
	if OpForms.IsDurable(Found.Form) and Found.ErrorsInARow >= Limits.ErrorsBeforeUnresolved then
		Writers.NoteNotTook(Writer, Found)
		Answering.AnswerCallFailed(State, Commands, Found, Reasons.Unresolved)
	end
end

local function RetryAfterError(Writer: WriterState, Clock: number, Limits: Limits)
	Writer.ErrorsInARow += 1
	Writer.RetryAt = Clock + RetryGap(Writer.ErrorsInARow, Limits)
end

local function OnError(
	State: ServerState,
	Writer: WriterState,
	Sent: { SentOp },
	Clock: number,
	Limits: Limits,
	Commands: { Command }
)
	for _, Carried in Sent do
		local Found = Writers.FindOp(Writer.Queue, OpForms.SequenceOf(Carried.Form))
		if Found ~= nil then
			CountError(State, Writer, Found, Limits, Commands)
		end
	end
	RetryAfterError(Writer, Clock, Limits)
end

local function OnRefusedBeforeStore(
	State: ServerState,
	Writer: WriterState,
	RequestId: number,
	Sent: { SentOp },
	Clock: number,
	Limits: Limits,
	Commands: { Command }
)
	local Elsewhere = SequencesCarriedElsewhere(Writer, RequestId)
	for _, Carried in Sent do
		local Sequence = OpForms.SequenceOf(Carried.Form)
		local Found = Writers.FindOp(Writer.Queue, Sequence)
		if Found == nil or Found.IsHeard then
			continue
		end
		if Found.IsClean and not Elsewhere[Sequence] and OpForms.IsDurable(Found.Form) then
			Writers.NoteNotTook(Writer, Found)
			Writers.MarkHeard(Writer, Found)
			Answering.AnswerCallFailed(State, Commands, Found, Reasons.Busy)
			OpOutcomes.Stop(State, Commands, Writer.Key, Found)
		elseif not Found.IsClean or Elsewhere[Sequence] then
			CountError(State, Writer, Found, Limits, Commands)
		end
	end
	RetryAfterError(Writer, Clock, Limits)
end

local function NoteFinalRetry(Writer: WriterState, RequestId: number)
	local Final = Writer.Final
	if Final ~= nil and Final.RequestId == RequestId then
		Writer.FinalWaitsRetry = true
	end
end

local function MoveFor(Op: Op, Report: Report, IsClean: boolean): Move
	local Form = Op.Form
	if Form.Kind == "Cut" or Form.Kind == "Tent" or Form.Kind == "Commit" then
		error(UnqueuedOpAnswered)
	end
	local Carried = Op.Incarnation
	if Carried == nil then
		error(NeverSentCarried)
	end
	if Form.Kind == "Hopeful" then
		return Answers.HopefulAnswer(Report, IsClean, Carried)
	end
	return Answers.DurableAnswer(Report, IsClean, Form.Kind, Carried)
end

local function IsNotKnownToHaveTaken(Move: Move): boolean
	if Move.Kind == "Answer" then
		return not (Move.Answer.Kind == "Succeeded" and Move.Answer.Value == true)
	end
	return Move.Kind == "Emit" and Move.Fate.Kind ~= "Took"
end

local function SendAgainWithIfShared(Op: Op, KeyId: KeyIdHeard, Undecided: Move): Move
	if not Incarnations.SharesFreshId(Op.Incarnation, KeyId.Carried) then
		return Undecided
	end
	return { Kind = "SendAgainWith", Identity = KeyId.Identity }
end

local function OnAnswer(Writer: WriterState, RequestId: number, Sent: { SentOp }, Note: Note): { OpMove }
	Writer.ErrorsInARow = 0
	Writer.RetryAt = nil
	Writer.FinalWaitsRetry = false
	local Elsewhere = SequencesCarriedElsewhere(Writer, RequestId)
	local Moves: { OpMove } = {}
	local KeyId: KeyIdHeard? = nil
	for Position, Carried in Sent do
		local Sequence = OpForms.SequenceOf(Carried.Form)
		local Found = Writers.FindOp(Writer.Queue, Sequence)
		if Found == nil or Found.IsHeard then
			continue
		end
		if Note.Closure.Ran[Sequence] then
			Found.IsClean = false
		end
		Found.ErrorsInARow = 0
		local IsClean = Found.IsClean and not Elsewhere[Sequence]
		local Report = Note.Reports[Position] or UndecidedReport
		local Move = MoveFor(Found, Report, IsClean)
		if KeyId ~= nil and Report.Kind == "Undecided" and IsClean then
			Move = SendAgainWithIfShared(Found, KeyId, Move)
		elseif Move.Kind == "SendAgainWith" then
			KeyId = { Carried = Found.Incarnation, Identity = Move.Identity }
		end
		if Move.Kind == "Emit" and Move.Fate.Kind == "Turned" then
			Writers.NoteTurnedAway(Writer, Found)
		elseif IsNotKnownToHaveTaken(Move) then
			Writers.NoteNotTook(Writer, Found)
		end
		table.insert(Moves, { Op = Found, Move = Move, Report = Report })
	end
	return Moves
end

local function AheadLandsAt(Moves: { OpMove }, Limits: Limits): number?
	local Earliest: number? = nil
	for _, Moved in Moves do
		local Stamp = Moved.Op.Stamp
		if Moved.Report.Kind ~= "Ahead" or Moved.Move.Kind ~= "SendAgain" or Stamp == nil then
			continue
		end
		local LandsAt = Stamp - Limits.Ahead
		if Earliest == nil or LandsAt < Earliest then
			Earliest = LandsAt
		end
	end
	return Earliest
end

local function PaceAhead(Writer: WriterState, RoundsBefore: number, LandsAt: number, Clock: number, Limits: Limits)
	Writer.ErrorsInARow = RoundsBefore + 1
	Writer.RetryAt = math.min(LandsAt, Clock + RetryGap(Writer.ErrorsInARow, Limits))
end

local function AfterAnswer(Writer: WriterState, RequestId: number, Clock: number)
	if Writer.Out ~= nil and Writer.Out.RequestId == RequestId then
		Writer.Out = nil
	end
	if Writer.Final ~= nil and Writer.Final.RequestId == RequestId then
		Writer.Final = nil
	end
	Writers.PruneHeard(Writer, Clock)
end

local function NameText(Named: Name): string
	if Named.Kind == "Game" then
		return Named.Text
	end
	return `({Named.Server}, {Named.Counter})`
end

local function WarnAbout(Key: StoreKey, Text: string): Command
	return { Kind = "Warn", Key = Key, Text = Text }
end

local function WarnFromNote(Key: StoreKey, Note: Note, Commands: { Command })
	for _, Warning in Note.Warnings do
		if Warning.Kind == "AlsoCut" then
			local Text = string.format(AlsoCutWarning, NameText(Warning.Name))
			table.insert(Commands, WarnAbout(Key, Text))
		elseif Warning.Kind == "CreatedAfterErase" then
			table.insert(Commands, WarnAbout(Key, CreatedAfterEraseWarning))
		end
	end
end

local function LearnFromNote(
	State: ServerState,
	Writer: WriterState,
	Entry: CacheEntry,
	Setup: Setup,
	Note: Note,
	Commands: { Command }
)
	Numbers.LearnFromNote(State, Entry, Writer.Key, Setup, Note)
	WarnFromNote(Writer.Key, Note, Commands)
	Unreadable.WarnOfReport(State, Writer.Key, Note.Reports[1], Commands)
end

return {
	HasUnheard = HasUnheard,
	MaySend = MaySend,
	MaySendFinal = MaySendFinal,
	StampFor = StampFor,
	BuildRequest = BuildRequest,
	SendOut = SendOut,
	SendFinal = SendFinal,
	RetryGap = RetryGap,
	OnError = OnError,
	OnRefusedBeforeStore = OnRefusedBeforeStore,
	NoteFinalRetry = NoteFinalRetry,
	OnAnswer = OnAnswer,
	AheadLandsAt = AheadLandsAt,
	PaceAhead = PaceAhead,
	AfterAnswer = AfterAnswer,
	LearnFromNote = LearnFromNote,
	WarnFromNote = WarnFromNote,
}
