--!strict
--!optimize 2

--[=[
	Writer: the writer of one key and its queue (record sheets 7, 8 and 10).

	An op that finds SequenceMax passed waits unnumbered until every fate is heard and the writer holds a new
	number. Cut ops are never queued. A sent op is never shed: Busy means nothing was sent. Answering answers an op's
	call.

	Return type: A plain table of functions, and the JoinOutcome type.
	Example usage:
		local KeyWriter = Writer.NewWriter(State, Key)
		Writer.Join(KeyWriter, Waiting, Limits)
--]=]

local Book = require("../Stored/Book")
local Cache = require("../Reading/Cache")
local Incarnations = require("./Incarnations")
local Names = require("../Encoding/Names")
local Numbers = require("./Numbers")
local OpForms = require("../Judging/OpForms")
local Reasons = require("../Constants/Reasons")
local Record = require("../Constants/Record")
local Shapes = require("../Shapes")
local Sorted = require("../Sorted")

type Identity = Book.Identity
type StoreKey = Names.StoreKey
type Reason = Reasons.Reason
type Limits = Shapes.Limits
type OpForm = Shapes.OpForm
type WaitingForm = Shapes.WaitingForm
type WaitingOp = Shapes.WaitingOp
type Op = Shapes.Op
type ResumedWriter = Shapes.ResumedWriter
type WriterState = Shapes.WriterState
type ServerState = Shapes.ServerState

local SequenceOf = OpForms.SequenceOf

export type JoinOutcome =
	{ read Kind: "Numbered", read Sequence: number }
	| { read Kind: "Waiting" }
	| { read Kind: "FirstWaiting" }

local WaitingOutcome: JoinOutcome = table.freeze({ Kind = "Waiting" :: "Waiting" })
local FirstWaitingOutcome: JoinOutcome = table.freeze({ Kind = "FirstWaiting" :: "FirstWaiting" })

local RoutingFault = "Writer: this call is never made."
local NoStartingNumber = `{RoutingFault} A writer needs a number from a cache entry or the shared one.`

local function WriterFor(State: ServerState, Key: StoreKey): WriterState?
	return Cache.StoreOf(State, Key).Writers[Names.KeyText(Key)]
end

local function CanStartWriter(State: ServerState, Key: StoreKey): boolean
	local Entry = Cache.FindEntry(State, Key)
	if Entry ~= nil and Entry.Resumed ~= nil then
		return true
	end
	return State.WriterNumber ~= nil
end

local function StartingNumbers(State: ServerState, Key: StoreKey): ResumedWriter
	local Entry = Cache.FindEntry(State, Key)
	if Entry ~= nil and Entry.Resumed ~= nil then
		local Resumed = Entry.Resumed
		Entry.Resumed = nil
		return Resumed
	end
	local Shared = State.WriterNumber
	if Shared == nil then
		error(NoStartingNumber)
	end
	return { WriterId = Shared, NextSequence = Record.FirstSequence }
end

local function NewWriter(State: ServerState, Key: StoreKey): WriterState
	local Store = Cache.StoreOf(State, Key)
	local Start = StartingNumbers(State, Key)
	local Created: WriterState = {
		Key = Key,
		Text = Names.KeyText(Key),
		Kind = Cache.KindOfKey(Key),
		WriterId = Start.WriterId,
		NextSequence = Start.NextSequence,
		Queue = {},
		Waiting = {},
		Acknowledged = Start.NextSequence - 1,
		ErrorsInARow = 0,
		FinalWaitsRetry = false,
		QueuedHopefulBytes = 0,
		QueuedHopeful = 0,
		FirstSequence = Start.NextSequence,
		NotTook = {},
		MintedByCall = {},
		TidyOwed = false,
	}
	Store.Writers[Created.Text] = Created
	return Created
end

local function WriterOrNew(State: ServerState, Key: StoreKey): WriterState
	local Existing = WriterFor(State, Key)
	if Existing == nil then
		return NewWriter(State, Key)
	end
	return Existing
end

local function NumberedForm(Form: WaitingForm, Sequence: number): OpForm
	if Form.Kind == "Minted" then
		return { Kind = "Minted", Sequence = Sequence }
	end
	if Form.Kind == "Timed" then
		return { Kind = "Timed", Sequence = Sequence, Name = Form.Name }
	end
	if Form.Kind == "Untimed" then
		return { Kind = "Untimed", Sequence = Sequence, Name = Form.Name }
	end
	return { Kind = "Hopeful", Sequence = Sequence, ViewCuts = Form.ViewCuts }
end

local function NumberedOp(Waiting: WaitingOp, Sequence: number): Op
	local Numbered: Op = {
		Form = NumberedForm(Waiting.Form, Sequence),
		OpKind = Waiting.OpKind,
		Terms = Waiting.Terms,
		JoinedAt = Waiting.JoinedAt,
		MustExist = Waiting.MustExist,
		Size = Waiting.Size,
		IsSent = false,
		CallId = Waiting.CallId,
		IsStep = Waiting.IsStep,
		GivesState = Waiting.GivesState,
		ErrorsInARow = 0,
		IsClean = true,
		IsHeard = false,
		IsAnswered = false,
		OwesOutcome = false,
	}
	if Waiting.Form.Kind == "Timed" then
		Numbered.Stamp = Waiting.Form.Stamp
	end
	return Numbered
end

local function UnheardCount(Writer: WriterState): number
	local Count = #Writer.Waiting
	for _, Op in Writer.Queue do
		if not Op.IsHeard then
			Count += 1
		end
	end
	return Count
end

local function HasUnheardOf(Writer: WriterState, CallId: number): boolean
	for _, Waiting in Writer.Waiting do
		if Waiting.CallId == CallId then
			return true
		end
	end
	for _, Op in Writer.Queue do
		if Op.CallId == CallId and not Op.IsHeard then
			return true
		end
	end
	return false
end

local function Join(Writer: WriterState, Waiting: WaitingOp, Limits: Limits): JoinOutcome
	Writer.IdleSince = nil
	if Waiting.Form.Kind == "Hopeful" then
		Writer.QueuedHopeful += 1
		Writer.QueuedHopefulBytes += Waiting.Size
	end
	if #Writer.Waiting > 0 or Writer.NextSequence > Limits.SequenceMax then
		table.insert(Writer.Waiting, Waiting)
		if #Writer.Waiting > 1 or Writer.NextWriterId ~= nil then
			return WaitingOutcome
		end
		return FirstWaitingOutcome
	end
	local Sequence = Writer.NextSequence
	table.insert(Writer.Queue, NumberedOp(Waiting, Sequence))
	Writer.NextSequence += 1
	return { Kind = "Numbered", Sequence = Sequence }
end

local function ShedHopeful(QueuedOps: number, QueuedBytes: number, Waiting: WaitingOp, Limits: Limits): Reason?
	if QueuedOps + 1 > Limits.QueueRoomOps then
		return Reasons.Backlog
	end
	if QueuedBytes + Waiting.Size > Limits.QueueRoomBytes then
		return Reasons.Backlog
	end
	return nil
end

local function Shed(Writer: WriterState, Waiting: WaitingOp, Limits: Limits): Reason?
	if Waiting.Form.Kind == "Hopeful" then
		return ShedHopeful(Writer.QueuedHopeful, Writer.QueuedHopefulBytes, Waiting, Limits)
	end
	if UnheardCount(Writer) >= Limits.QueueOpsMax then
		return Reasons.Busy
	end
	return nil
end

local function MarkHeard(Writer: WriterState, Op: Op)
	if Op.IsHeard then
		return
	end
	Op.IsHeard = true
	if Op.Form.Kind == "Hopeful" then
		Writer.QueuedHopeful -= 1
		Writer.QueuedHopefulBytes -= Op.Size
	end
end

local function NoteNotTook(Writer: WriterState, Op: Op)
	if Op.Form.Kind == "Minted" or Op.Form.Kind == "Hopeful" then
		Writer.NotTook[Op.Form.Sequence] = "Unknown"
	end
end

local function NoteTurnedAway(Writer: WriterState, Op: Op)
	if Op.Form.Kind == "Minted" or Op.Form.Kind == "Hopeful" then
		Writer.NotTook[Op.Form.Sequence] = "TurnedAway"
	end
end

local function Restamp(Op: Op, Clock: number, NoteHorizon: number)
	Op.Stamp = math.max(Clock, NoteHorizon + 1)
end

local function Reincarnate(Op: Op, Identity: Identity?)
	Op.Incarnation = Incarnations.TagOfValue(Identity)
end

local function AckOf(Ops: { Op }, NextSequence: number): number
	for _, Op in Ops do
		if not Op.IsHeard then
			return SequenceOf(Op.Form) - 1
		end
	end
	return NextSequence - 1
end

local function PruneHeard(Writer: WriterState, Clock: number)
	local Queue = Writer.Queue
	local Acknowledged = AckOf(Queue, Writer.NextSequence)
	Writer.Acknowledged = Acknowledged
	local Heard = 0
	while Heard < #Queue and SequenceOf(Queue[Heard + 1].Form) <= Acknowledged do
		Heard += 1
	end
	Writer.Queue = if Heard == 0 then Queue else table.move(Queue, Heard + 1, #Queue, 1, {})
	local IsIdle = #Writer.Queue == 0 and #Writer.Waiting == 0 and Writer.Out == nil and Writer.Final == nil
	if not IsIdle then
		Writer.IdleSince = nil
	elseif Writer.IdleSince == nil then
		Writer.IdleSince = Clock
	end
end

local function Renumber(Writer: WriterState)
	local Taken = Writer.NextWriterId
	if Taken == nil or #Writer.Queue > 0 or Writer.Out ~= nil or Writer.Final ~= nil then
		return
	end
	Writer.NextWriterId = nil
	Writer.WriterId = Taken
	Writer.NextSequence = Record.FirstSequence
	Writer.FirstSequence = Record.FirstSequence
	Writer.Acknowledged = Record.FirstSequence - 1
	Writer.NotTook = {}
	for _, Waiting in Writer.Waiting do
		if Waiting.Form.Kind == "Hopeful" and Waiting.CallId ~= nil then
			Writer.MintedByCall[Waiting.CallId] =
				{ Kind = "Minted", WriterId = Writer.WriterId, Sequence = Writer.NextSequence }
		end
		table.insert(Writer.Queue, NumberedOp(Waiting, Writer.NextSequence))
		Writer.NextSequence += 1
	end
	Writer.Waiting = {}
end

local function TakeWriterNumber(State: ServerState, Key: StoreKey, Number: number)
	local Writer = WriterFor(State, Key)
	if Writer == nil then
		Numbers.EntryFor(State, Key).Resumed = { WriterId = Number, NextSequence = Record.FirstSequence }
		return
	end
	Writer.NextWriterId = Number
	Renumber(Writer)
end

local function IdleDropAt(Writer: WriterState, Limits: Limits): number?
	if Writer.IdleSince == nil then
		return nil
	end
	return Writer.IdleSince + Limits.MintedWindow + Record.SkewSigmas * Limits.Sigma
end

local function DropIdle(State: ServerState, Clock: number)
	for _, Name in Sorted.SortedTexts(State.Stores) do
		local Store = State.Stores[Name]
		local Limits = Store.Setup.Limits
		local function IsDropDue(Writer: WriterState): boolean
			local DropAt = IdleDropAt(Writer, Limits)
			return DropAt ~= nil and Clock >= DropAt
		end
		for _, Text in Sorted.SortedDueTexts(Store.Writers, IsDropDue) do
			local Writer = Store.Writers[Text]
			local Entry = Numbers.EntryFor(State, Writer.Key)
			Entry.Resumed = { WriterId = Writer.WriterId, NextSequence = Writer.NextSequence }
			Store.Writers[Text] = nil
		end
	end
end

local function FindOp(Queue: { Op }, Sequence: number): Op?
	local Low = 1
	local High = #Queue
	while Low <= High do
		local Middle = (Low + High) // 2
		local Found = SequenceOf(Queue[Middle].Form)
		if Found == Sequence then
			return Queue[Middle]
		end
		if Found < Sequence then
			Low = Middle + 1
		else
			High = Middle - 1
		end
	end
	return nil
end

return {
	WriterFor = WriterFor,
	CanStartWriter = CanStartWriter,
	NewWriter = NewWriter,
	WriterOrNew = WriterOrNew,
	FindOp = FindOp,
	Join = Join,
	Shed = Shed,
	ShedHopeful = ShedHopeful,
	Renumber = Renumber,
	TakeWriterNumber = TakeWriterNumber,
	IdleDropAt = IdleDropAt,
	DropIdle = DropIdle,
	UnheardCount = UnheardCount,
	HasUnheardOf = HasUnheardOf,
	AckOf = AckOf,
	PruneHeard = PruneHeard,
	MarkHeard = MarkHeard,
	NoteNotTook = NoteNotTook,
	NoteTurnedAway = NoteTurnedAway,
	Restamp = Restamp,
	Reincarnate = Reincarnate,
}
