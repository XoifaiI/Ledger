--!strict
--!optimize 2

--[=[
	Session: a player's key held open on this server (record sheet 13 and 12's Apply), with its key's text and idle
	read.

	Its view is Stored, the stored state it last showed, with the queued hopeful ops on top; it keeps the key's
	incarnation. Apply sends nothing. An op unnumbered at SequenceMax gets a Queued handle. IsBehind never clears.

	A pending Refresh may wait for this server's ends on the key, or for a read already out, before a read answers it.

	Return type: A plain table of functions, and the Session, PendingRefresh, RefreshWait, SessionState, Releasing,
	Shutdown,
	ApplyCall, ReleaseCall and Basis types.
	Example usage:
		local Sessions = Session.NewState()
		Session.Apply(State, Sessions, { CallId = 1, Key = Key, OpKind = "d", Terms = { d = 1 } }, Clock, Commands)
--]=]

local Beside = require("../Tx/Beside")
local Book = require("../Stored/Book")
local Cache = require("../Reading/Cache")
local Decide = require("../Judging/Decide")
local Events = require("../Events")
local Json = require("../Encoding/Json")
local JudgingShapes = require("../Judging/Shapes")
local Marks = require("../Tx/Legs/Marks")
local Names = require("../Encoding/Names")
local Numbers = require("../Writing/Numbers")
local Reads = require("../Reading/Reads")
local Reasons = require("../Constants/Reasons")
local Replies = require("../Replies")
local Sending = require("../Writing/Sending")
local Shapes = require("../Shapes")
local Showables = require("../Reading/Showables")
local Value = require("../Stored/Value")
local Work = require("../Stored/Items/Work")
local Writers = require("../Writing/Writer")

type Answer = Events.Answer
type Command = Events.Command
type Identity = Book.Identity
type StoreKey = Names.StoreKey
type Reason = Reasons.Reason
type Kept = Value.Kept
type EscrowMark = Work.EscrowMark
type Mark = Work.Mark
type Verdict = JudgingShapes.Verdict
type ReadOut = Reads.ReadOut
type Opened = Reads.Opened
type OpenedEmpty = Reads.OpenedEmpty
type AskedName = Shapes.AskedName
type Limits = Shapes.Limits
type Setup = Shapes.Setup
type WaitingOp = Shapes.WaitingOp
type WriterState = Shapes.WriterState
type JoinOutcome = Writers.JoinOutcome
type ServerState = Shapes.ServerState

type Fields = { [unknown]: unknown }

export type RefreshWait = "Ends" | "Read"

export type PendingRefresh = { read CallId: number, read Text: string, read Deadline: number, Wait: RefreshWait? }

export type Session = {
	Key: StoreKey,
	read Text: string,
	WriteCount: number,
	CutCount: number,
	Horizon: number?,
	Identity: Identity?,
	ShowsKey: boolean,
	Stored: Fields,
	View: Fields,
	Marks: { Mark },
	MayCreate: boolean,
	PushedAt: number,
	IdleReadAt: number,
	IdleOut: number?,
	PushAsked: boolean,
	IsBehind: boolean,
}

export type Releasing = {
	read CallId: number,
	read RequestId: number?,
	read Deadline: number,
}

export type Shutdown = { read Kind: "Ending", read CallId: number, read Deadline: number } | { read Kind: "Ended" }

export type SessionState = {
	Open: { [string]: Session },
	Releasing: { [string]: Releasing },
	IdleReads: { [number]: string },
	Refreshing: { PendingRefresh },
	Shutdown: Shutdown?,
}

export type ApplyCall = {
	read CallId: number,
	read Key: StoreKey,
	read OpKind: string,
	read Terms: unknown,
}

export type ReleaseCall = { read CallId: number, read Key: StoreKey }

export type Basis = {
	read Writes: number,
	read Cuts: number,
	read Horizon: number?,
	read Identity: Identity?,
	read ShowsKey: boolean,
	read Stored: Fields,
	read Marks: { Mark },
}

local ViewStream = "View"

local RoutingFault = "Session: this call is never made."
local NotALoad = `{RoutingFault} A session opens only from a read made for a Load.`
local AlreadyOpen = `{RoutingFault} A key with an open session is not loaded again; the API keeps one load per player.`

local function NewState(): SessionState
	return { Open = {}, Releasing = {}, IdleReads = {}, Refreshing = {} }
end

local function EmitView(Commands: { Command }, Open: Session)
	local Emit: Command = { Kind = "Emit", Stream = ViewStream, Key = Open.Key, Value = Open.View }
	table.insert(Commands, Emit)
end

local function BasisOfKept(Kept: Kept, Viewed: Fields): Basis
	local StoredBook = Kept.Book
	return {
		Writes = StoredBook.Writes,
		Cuts = StoredBook.Cuts,
		Horizon = StoredBook.Horizon,
		Identity = StoredBook.Identity,
		ShowsKey = true,
		Stored = Viewed,
		Marks = StoredBook.Work,
	}
end

local function IsQuiet(Writer: WriterState?): boolean
	if Writer == nil then
		return true
	end
	if Sending.HasUnheard(Writer) then
		return false
	end
	return #Writer.Waiting == 0
end

local function AnswerRefreshesOf(
	Sessions: SessionState,
	Text: string,
	Given: Answer,
	IsEvery: boolean,
	Commands: { Command }
)
	local Kept: { PendingRefresh } = {}
	for _, Pending in Sessions.Refreshing do
		if Pending.Text == Text and (IsEvery or Pending.Wait == nil) then
			Replies.Reply(Commands, Pending.CallId, Given)
		else
			table.insert(Kept, Pending)
		end
	end
	Sessions.Refreshing = Kept
end

local function AnswerRefreshes(Sessions: SessionState, Text: string, Given: Answer, Commands: { Command })
	AnswerRefreshesOf(Sessions, Text, Given, false, Commands)
end

local function AnswerEveryRefresh(Sessions: SessionState, Text: string, Given: Answer, Commands: { Command })
	AnswerRefreshesOf(Sessions, Text, Given, true, Commands)
end

local function AnswerRefreshesDue(Sessions: SessionState, Clock: number, Commands: { Command })
	local Kept: { PendingRefresh } = {}
	for _, Pending in Sessions.Refreshing do
		if Clock >= Pending.Deadline then
			Replies.ReplyFailed(Commands, Pending.CallId, Reasons.Unresolved)
		else
			table.insert(Kept, Pending)
		end
	end
	Sessions.Refreshing = Kept
end

local function FillEntry(State: ServerState, Open: Session)
	local Setup = Cache.StoreOf(State, Open.Key).Setup
	local Entry = Numbers.EntryFor(State, Open.Key)
	Numbers.FillEntry(Entry, Open.Key, Setup, Open.Horizon, Open.Identity, Open.ShowsKey)
end

local function DefaultBasis(Setup: Setup): Basis
	return { Writes = 0, Cuts = 0, ShowsKey = false, Stored = Value.CopyDefault(Setup.Build.Default), Marks = {} }
end

local function LayOp(
	Setup: Setup,
	Current: Fields,
	OpKind: string,
	Terms: unknown,
	Escrows: { EscrowMark },
	Clock: number
): Fields
	local Verdict = Decide.DecideOnState(Setup, Current, OpKind, Terms, Escrows, Clock)
	if Verdict.Kind == "Took" then
		return Verdict.State
	end
	return Current
end

local function LaidOn(Setup: Setup, Base: Fields, Escrows: { EscrowMark }, Writer: WriterState?, Clock: number): Fields
	if Writer == nil then
		return Base
	end
	local Laid = Base
	for _, Op in Writer.Queue do
		if Op.IsHeard or Op.Form.Kind ~= "Hopeful" then
			continue
		end
		Laid = LayOp(Setup, Laid, Op.OpKind, Op.Terms, Escrows, Clock)
	end
	for _, Waiting in Writer.Waiting do
		if Waiting.Form.Kind == "Hopeful" then
			Laid = LayOp(Setup, Laid, Waiting.OpKind, Waiting.Terms, Escrows, Clock)
		end
	end
	return Laid
end

local function QueuedOnStored(State: ServerState, Key: StoreKey, Stored: Fields, Work: { Mark }, Clock: number): Fields
	local Setup = Cache.StoreOf(State, Key).Setup
	return LaidOn(Setup, Stored, Marks.EscrowMarksOf(Work), Writers.WriterFor(State, Key), Clock)
end

local function OpenFrom(
	State: ServerState,
	Sessions: SessionState,
	Out: ReadOut,
	Taken: Basis,
	Clock: number,
	Commands: { Command }
)
	local Want = Out.Want
	if Want.Kind ~= "Load" then
		error(NotALoad)
	end
	local Text = Names.KeyText(Out.Key)
	if Sessions.Open[Text] ~= nil then
		error(AlreadyOpen)
	end
	local Opened: Session = {
		Key = Out.Key,
		Text = Text,
		WriteCount = Taken.Writes,
		CutCount = Taken.Cuts,
		Horizon = Taken.Horizon,
		Identity = Taken.Identity,
		ShowsKey = Taken.ShowsKey,
		Stored = Taken.Stored,
		View = QueuedOnStored(State, Out.Key, Taken.Stored, Taken.Marks, Clock),
		Marks = Taken.Marks,
		MayCreate = not Want.MustExist,
		PushedAt = Clock,
		IdleReadAt = Clock,
		PushAsked = false,
		IsBehind = false,
	}
	Sessions.Open[Text] = Opened
	Showables.Serve(State, Out.Key)
	Replies.Reply(Commands, Out.CallId, { Kind = "Succeeded", Value = Opened.View })
	EmitView(Commands, Opened)
end

local function Load(State: ServerState, Sessions: SessionState, Found: Opened, Clock: number, Commands: { Command })
	OpenFrom(State, Sessions, Found.Out, BasisOfKept(Found.Kept, Found.Viewed), Clock, Commands)
end

local function LoadEmpty(
	State: ServerState,
	Sessions: SessionState,
	Found: OpenedEmpty,
	Clock: number,
	Commands: { Command }
)
	local Setup = Cache.StoreOf(State, Found.Out.Key).Setup
	OpenFrom(State, Sessions, Found.Out, DefaultBasis(Setup), Clock, Commands)
end

local function WaitingFor(Open: Session, Call: ApplyCall, Clock: number): WaitingOp
	return {
		Form = { Kind = "Hopeful", ViewCuts = Open.CutCount },
		OpKind = Call.OpKind,
		Terms = Call.Terms,
		JoinedAt = Clock,
		MustExist = not Open.MayCreate,
		Size = Json.Size(Call.Terms),
		CallId = Call.CallId,
		IsStep = false,
	}
end

local function ShedFor(State: ServerState, Key: StoreKey, Waiting: WaitingOp, Limits: Limits): Reason?
	local Writer = Writers.WriterFor(State, Key)
	if Writer == nil then
		return Writers.ShedHopeful(0, 0, Waiting, Limits)
	end
	return Writers.Shed(Writer, Waiting, Limits)
end

local function ReasonOfNo(Verdict: Verdict): Reason
	if Verdict.Kind == "Refused" or Verdict.Kind == "NoState" then
		return Reasons.Refused
	end
	if Verdict.Kind == "Full" then
		return Reasons.Full
	end
	if Verdict.Kind == "Unreadable" then
		return Reasons.Busy
	end
	return Reasons.Invalid
end

local function NameGivenBack(Writer: WriterState, Outcome: JoinOutcome, CallId: number): AskedName
	if Outcome.Kind == "Numbered" then
		return { Kind = "Minted", WriterId = Writer.WriterId, Sequence = Outcome.Sequence }
	end
	return { Kind = "Queued", CallId = CallId }
end

local function DecideOnView(Setup: Setup, Open: Session, Call: ApplyCall, Clock: number): Verdict | "Busy"
	if #Open.Marks == 0 then
		return Decide.DecideOnState(Setup, Open.View, Call.OpKind, Call.Terms, Decide.NoMarks, Clock)
	end
	return Beside.ApplyBesideMarks(Setup, Open.View, Open.Marks, Call.OpKind, Call.Terms, Clock)
end

local function Apply(State: ServerState, Sessions: SessionState, Call: ApplyCall, Clock: number, Commands: { Command })
	local Open = Sessions.Open[Names.KeyText(Call.Key)]
	if Sessions.Shutdown ~= nil or Open == nil then
		return Replies.ReplyFailed(Commands, Call.CallId, Reasons.Closed)
	end
	local Setup = Cache.StoreOf(State, Call.Key).Setup
	local Waiting = WaitingFor(Open, Call, Clock)
	local Shed = ShedFor(State, Call.Key, Waiting, Setup.Limits)
	if Shed ~= nil then
		return Replies.ReplyFailed(Commands, Call.CallId, Shed)
	end
	local Verdict = DecideOnView(Setup, Open, Call, Clock)
	if Verdict == "Busy" then
		return Replies.ReplyFailed(Commands, Call.CallId, Reasons.Busy)
	end
	if Verdict.Kind ~= "Took" then
		return Replies.ReplyFailed(Commands, Call.CallId, ReasonOfNo(Verdict))
	end
	local Writer = Writers.WriterOrNew(State, Call.Key)
	local Outcome = Writers.Join(Writer, Waiting, Setup.Limits)
	if Outcome.Kind == "FirstWaiting" then
		table.insert(Commands, Numbers.AskWriterNumber(State, Call.Key, Setup.Limits))
	end
	Open.View = Verdict.State
	Replies.Reply(Commands, Call.CallId, { Kind = "Succeeded", Value = NameGivenBack(Writer, Outcome, Call.CallId) })
	EmitView(Commands, Open)
end

return {
	NewState = NewState,
	EmitView = EmitView,
	BasisOfKept = BasisOfKept,
	QueuedOnStored = QueuedOnStored,
	IsQuiet = IsQuiet,
	AnswerRefreshes = AnswerRefreshes,
	AnswerEveryRefresh = AnswerEveryRefresh,
	AnswerRefreshesDue = AnswerRefreshesDue,
	FillEntry = FillEntry,
	Load = Load,
	LoadEmpty = LoadEmpty,
	Apply = Apply,
}
