--!strict
--!optimize 2

--[=[
	Reads: the record's reads (record sheet 14): Peek, Inspect, Peek with Fresh, Losses, Load, the read DidApply
	starts, and a copy holder's or follower's, which hand their result on.

	A state is shown as Tx/Beside's Showing says; unclean marks give Deciders, for Tx/Unclean. A read waits for
	work in HelpId and answers Unresolved at OpBound. A value below the shown count is read again after the first
	retry gap: an answer that is not an error resets the gap (record 3.2).

	Return type: A plain table of functions, the TookAnswer, UnresolvedAnswer, BehindAnswer and FreshRequest, and the
	ReadKind, Want, ReadOut, Next, ReadContext, Opened, OpenedEmpty, Handed, LoadCall and ReadCall types.
	Example usage:
		local Out = Reads.Start(State, { CallId = 1, Key = Key }, "Peek", Clock, Commands)
--]=]

local Answers = require("../Writing/Answers")
local Beside = require("../Tx/Beside")
local Book = require("../Stored/Book")
local Cache = require("./Cache")
local Events = require("../Events")
local JudgingShapes = require("../Judging/Shapes")
local Lookup = require("../Stored/Lookup")
local Losses = require("../Stored/Items/Losses")
local Names = require("../Encoding/Names")
local Numbers = require("../Writing/Numbers")
local Reasons = require("../Constants/Reasons")
local Replies = require("../Replies")
local Sending = require("../Writing/Sending")
local Shapes = require("../Shapes")
local Showables = require("./Showables")
local Shown = require("./Shown")
local TxShapes = require("../Tx/Shapes")
local Unreadable = require("./Unreadable")
local Value = require("../Stored/Value")
local View = require("./View")
local Work = require("../Stored/Items/Work")

type Answer = Events.Answer
type Command = Events.Command
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type Book = Book.Book
type LossRecords = Losses.LossRecords
type Name = Names.Name
type StoreKey = Names.StoreKey
type EndWorkReport = JudgingShapes.EndWorkReport
type Value = Value.Value
type Kept = Value.Kept
type Report = JudgingShapes.Report
type Request = Shapes.Request
type Setup = Shapes.Setup
type ServerState = Shapes.ServerState
type StandingMark = Work.StandingMark
type AbortedUse = TxShapes.AbortedUse
type Cause = Unreadable.Cause
type Served = Showables.Served
type Fields = { [unknown]: unknown }

export type ReadKind = "Peek" | "Inspect" | "PeekFresh" | "Losses"

export type Want =
	{ read Kind: "Peek" }
	| { read Kind: "Inspect" }
	| { read Kind: "PeekFresh" }
	| { read Kind: "Losses" }
	| { read Kind: "DidApply", read Name: Name, read Stamp: number?, read Probe: Request? }
	| { read Kind: "Load", read MustExist: boolean }
	| { read Kind: "Copy" }
	| { read Kind: "Follow" }

export type ReadOut = {
	read CallId: number,
	read Key: StoreKey,
	read Want: Want,
	read Started: number,
	RequestId: number,
	ErrorsInARow: number,
	RetryAt: number?,
	HelpId: number?,
}

export type Opened = {
	read Kind: "Opened",
	read Out: ReadOut,
	read Kept: Kept,
	read Viewed: { [unknown]: unknown },
}

export type OpenedEmpty = { read Kind: "OpenedEmpty", read Out: ReadOut }

export type Handed = { read Kind: "Handed", read Out: ReadOut, read Answer: Answer }

export type Next =
	{ read Kind: "Done" }
	| { read Kind: "Reading", read Out: ReadOut }
	| { read Kind: "EndWork", read Out: ReadOut, read Report: EndWorkReport }
	| {
		read Kind: "Deciders",
		read Out: ReadOut,
		read Kept: Kept,
		read Viewed: Fields,
		read Marks: { StandingMark },
	}
	| Opened
	| OpenedEmpty
	| Handed

export type ReadContext = {
	read Clock: number,
	read Served: Served,
	read IsSilent: boolean,
	read Aborted: { AbortedUse },
}

export type LoadCall = { read CallId: number, read Key: StoreKey, read MustExist: boolean }

export type ReadCall = { read CallId: number, read Key: StoreKey }

local Wants: { [ReadKind]: Want } = {
	Peek = table.freeze({ Kind = "Peek" :: "Peek" }),
	Inspect = table.freeze({ Kind = "Inspect" :: "Inspect" }),
	PeekFresh = table.freeze({ Kind = "PeekFresh" :: "PeekFresh" }),
	Losses = table.freeze({ Kind = "Losses" :: "Losses" }),
}
local DoneNext: Next = table.freeze({ Kind = "Done" :: "Done" })

local FreshRequest: Request = table.freeze({ Kind = "Fresh" :: "Fresh" })
local TookAnswer: Answer = table.freeze({ Kind = "Succeeded" :: "Succeeded", Value = true })

local UnresolvedAnswer = table.freeze(Replies.FailedAnswer(Reasons.Unresolved))
local ExpiredAnswer = table.freeze(Replies.FailedAnswer(Reasons.Expired))
local MissingAnswer = table.freeze(Replies.FailedAnswer(Reasons.Missing))
local BehindAnswer = table.freeze(Replies.FailedAnswer(Reasons.Behind))

local function UnreadableAnswer(State: ServerState, Out: ReadOut, Cause: Cause, Commands: { Command }): Answer
	Unreadable.Warn(State, Out.Key, Cause, Commands)
	return Replies.FailedAnswer(Unreadable.ReasonOf(Cause))
end

local function IsHanded(Want: Want): boolean
	return Want.Kind == "Copy" or Want.Kind == "Follow"
end

local function EndRead(Commands: { Command }, Out: ReadOut, Given: Answer): Next
	if IsHanded(Out.Want) then
		return { Kind = "Handed", Out = Out, Answer = Given }
	end
	Replies.Reply(Commands, Out.CallId, Given)
	return DoneNext
end

local function MissingNext(Out: ReadOut, Commands: { Command }): Next
	if Out.Want.Kind == "Load" then
		return { Kind = "OpenedEmpty", Out = Out }
	end
	return EndRead(Commands, Out, MissingAnswer)
end

local function RequestFor(State: ServerState, Setup: Setup, Out: ReadOut): Request?
	local Want = Out.Want
	if Want.Kind == "PeekFresh" then
		return FreshRequest
	end
	if Want.Kind == "DidApply" then
		return Want.Probe
	end
	if Want.Kind == "Losses" then
		return nil
	end
	if Shown.IsAbsentWithBit(State, Out.Key) then
		return FreshRequest
	end
	return nil
end

local function Issue(State: ServerState, Setup: Setup, Out: ReadOut, RequestId: number, Commands: { Command }): Next
	Out.RequestId = RequestId
	Out.RetryAt = nil
	local Request = RequestFor(State, Setup, Out)
	if Request == nil then
		local Get: Command = { Kind = "Get", RequestId = RequestId, Target = Out.Key }
		table.insert(Commands, Get)
	else
		local Update: Command = { Kind = "Update", RequestId = RequestId, Target = Out.Key, Request = Request }
		table.insert(Commands, Update)
	end
	return { Kind = "Reading", Out = Out }
end

local function StartWant(State: ServerState, Call: ReadCall, Want: Want, Clock: number, Commands: { Command }): ReadOut
	local RequestId = Numbers.NewRequestId(State)
	local Out: ReadOut = {
		CallId = Call.CallId,
		Key = Call.Key,
		Want = Want,
		Started = Clock,
		RequestId = RequestId,
		ErrorsInARow = 0,
	}
	Issue(State, Cache.StoreOf(State, Call.Key).Setup, Out, RequestId, Commands)
	return Out
end

local function Start(State: ServerState, Call: ReadCall, Kind: ReadKind, Clock: number, Commands: { Command }): ReadOut
	return StartWant(State, Call, Wants[Kind], Clock, Commands)
end

local function StartLoad(State: ServerState, Call: LoadCall, Clock: number, Commands: { Command }): ReadOut
	local Want: Want = { Kind = "Load", MustExist = Call.MustExist }
	return StartWant(State, Call, Want, Clock, Commands)
end

local function StoredSaysTook(StoredBook: Book, Name: Name): boolean
	local Held = Lookup.HeldOfAsked(StoredBook, Name)
	if Held ~= nil and Held.Kind == "Fated" and Answers.IsTook(Held.Fate) then
		return true
	end
	return Lookup.UntimedTookOfAsked(StoredBook, Name)
end

local function IsForgottenAnyKind(Horizon: number, CutHorizon: number, Stamp: number?): boolean
	return Stamp ~= nil and Stamp <= math.max(Horizon, CutHorizon)
end

local function DidApplyOfStored(StoredBook: Book, Name: Name, Stamp: number?): Answer
	if StoredSaysTook(StoredBook, Name) then
		return TookAnswer
	end
	local IsForgotten = IsForgottenAnyKind(StoredBook.Horizon, StoredBook.CutHorizon, Stamp)
	if IsForgotten and Lookup.HeldOfAsked(StoredBook, Name) == nil then
		return ExpiredAnswer
	end
	return UnresolvedAnswer
end

local function IsPastBound(Out: ReadOut, Clock: number, Setup: Setup): boolean
	return Clock - Out.Started >= Setup.Limits.OpBound
end

local function ReadAgain(
	State: ServerState,
	Setup: Setup,
	Out: ReadOut,
	Context: ReadContext,
	Commands: { Command }
): Next
	if IsPastBound(Out, Context.Clock, Setup) then
		return EndRead(Commands, Out, UnresolvedAnswer)
	end
	if Context.IsSilent then
		return { Kind = "Reading", Out = Out }
	end
	local RequestId = Numbers.NewRequestId(State)
	return Issue(State, Setup, Out, RequestId, Commands)
end

local function Resume(State: ServerState, Out: ReadOut, Context: ReadContext, Commands: { Command }): Next
	return ReadAgain(State, Cache.StoreOf(State, Out.Key).Setup, Out, Context, Commands)
end

local function TimeOut(State: ServerState, Out: ReadOut, Clock: number, Commands: { Command }): Next
	if IsPastBound(Out, Clock, Cache.StoreOf(State, Out.Key).Setup) then
		return EndRead(Commands, Out, UnresolvedAnswer)
	end
	return { Kind = "Reading", Out = Out }
end

local function ReadAgainIn(Gap: number, Setup: Setup, Out: ReadOut, Context: ReadContext, Commands: { Command }): Next
	if IsPastBound(Out, Context.Clock, Setup) then
		return EndRead(Commands, Out, UnresolvedAnswer)
	end
	local WakeAt = math.min(Context.Clock + Gap, Out.Started + Setup.Limits.OpBound)
	Out.RetryAt = WakeAt
	local Wake: Command = { Kind = "Wake", At = WakeAt }
	table.insert(Commands, Wake)
	return { Kind = "Reading", Out = Out }
end

local function ReadAgainLater(Setup: Setup, Out: ReadOut, Context: ReadContext, Commands: { Command }): Next
	Out.ErrorsInARow += 1
	return ReadAgainIn(Sending.RetryGap(Out.ErrorsInARow, Setup.Limits), Setup, Out, Context, Commands)
end

local function ShowState(
	State: ServerState,
	Out: ReadOut,
	Kept: Kept,
	Viewed: Fields,
	Shows: Fields,
	Context: ReadContext,
	Commands: { Command }
): Next
	local Entry = Numbers.EntryFor(State, Out.Key)
	Entry.IsBehind = nil
	Beside.KeepShowable(Entry, Kept, Viewed, State, Out.Key, Context.Aborted, Context.Served)
	Shown.Show(State, Out.Key, Kept.Book.Writes, Kept.Book.Identity, Context.Clock, Context.Served.Open)
	if Out.Want.Kind == "Load" or IsHanded(Out.Want) then
		return { Kind = "Opened", Out = Out, Kept = Kept, Viewed = Shows }
	end
	if Out.Want.Kind == "Inspect" then
		local Inspected = table.clone(Kept)
		Inspected.State = Shows
		return EndRead(Commands, Out, { Kind = "Succeeded", Value = Inspected })
	end
	return EndRead(Commands, Out, { Kind = "Succeeded", Value = Shows })
end

local function ShowKept(
	State: ServerState,
	Setup: Setup,
	Out: ReadOut,
	Kept: Kept,
	Context: ReadContext,
	Commands: { Command }
): Next
	local Viewed = View.ViewState(Setup, Kept)
	if Viewed.Kind == "Behind" then
		Numbers.HearBehind(State, Out.Key)
		return EndRead(Commands, Out, BehindAnswer)
	end
	if Viewed.Kind == "Unreadable" then
		return EndRead(Commands, Out, UnreadableAnswer(State, Out, Viewed.Cause, Commands))
	end
	local Showing = Beside.Showing(State, Out.Key, Kept, Viewed.State, Context.Aborted)
	if Showing.Kind == "Unclean" then
		return { Kind = "Deciders", Out = Out, Kept = Kept, Viewed = Viewed.State, Marks = Showing.Marks }
	end
	return ShowState(State, Out, Kept, Viewed.State, Showing.State, Context, Commands)
end

local function AnswerStored(
	State: ServerState,
	Setup: Setup,
	Out: ReadOut,
	Kept: Kept,
	Context: ReadContext,
	Commands: { Command }
): Next
	local StoredBook = Kept.Book
	local Want = Out.Want
	if Want.Kind == "Losses" then
		local Records: LossRecords = {
			Events = StoredBook.Losses.Events,
			Returns = StoredBook.Losses.Returns,
			Slots = StoredBook.Slots,
		}
		return EndRead(Commands, Out, { Kind = "Succeeded", Value = Records })
	end
	if Want.Kind == "DidApply" then
		return EndRead(Commands, Out, DidApplyOfStored(StoredBook, Want.Name, Want.Stamp))
	end
	if not Shown.IsShown(State, Out.Key, StoredBook.Writes, StoredBook.Identity) then
		return ReadAgainIn(Setup.Limits.RetryGapFirst, Setup, Out, Context, Commands)
	end
	return ShowKept(State, Setup, Out, Kept, Context, Commands)
end

local function OnReadResult(
	State: ServerState,
	Out: ReadOut,
	Fetched: ReadOutcome,
	Context: ReadContext,
	Commands: { Command }
): Next
	local Setup = Cache.StoreOf(State, Out.Key).Setup
	if Fetched.Kind == "Failed" then
		return ReadAgainLater(Setup, Out, Context, Commands)
	end
	Out.ErrorsInARow = 0
	local Read = Numbers.LearnStored(State, Out.Key, Setup, Fetched, Context.Clock)
	if Read.Kind == "Unreadable" then
		return EndRead(Commands, Out, UnreadableAnswer(State, Out, Read.Cause, Commands))
	end
	if Read.Kind == "Nothing" then
		return MissingNext(Out, Commands)
	end
	return AnswerStored(State, Setup, Out, Read.Kept, Context, Commands)
end

local function AnswerCancel(State: ServerState, Out: ReadOut, Report: Report?, Commands: { Command }): Next
	if Report ~= nil and Report.Kind == "Overdue" then
		return { Kind = "EndWork", Out = Out, Report = Report }
	end
	if Report ~= nil and Report.Kind == "Missing" then
		return MissingNext(Out, Commands)
	end
	if Report ~= nil and Report.Kind == "Unreadable" and Report.Cause ~= "Amounts" then
		return EndRead(Commands, Out, UnreadableAnswer(State, Out, Report.Cause, Commands))
	end
	return EndRead(Commands, Out, UnresolvedAnswer)
end

local function OnUpdateResult(
	State: ServerState,
	Out: ReadOut,
	Result: Outcome,
	Context: ReadContext,
	Commands: { Command }
): Next
	local Setup = Cache.StoreOf(State, Out.Key).Setup
	if Result.Kind == "Err" then
		return ReadAgainLater(Setup, Out, Context, Commands)
	end
	Out.ErrorsInARow = 0
	local Note = Result.Note
	local Entry = Numbers.EntryFor(State, Out.Key)
	Numbers.LearnFromNote(State, Entry, Out.Key, Setup, Note)
	local Want = Out.Want
	if Want.Kind == "DidApply" then
		Unreadable.WarnOfReport(State, Out.Key, Note.ProbeReport, Commands)
		local IsForgotten = IsForgottenAnyKind(Note.Horizon, Note.CutHorizon, Want.Stamp)
		local Move = Answers.DidApplyAnswer(Note.ProbeReport, IsForgotten)
		if Move.Kind == "Answer" then
			return EndRead(Commands, Out, Move.Answer)
		end
		return { Kind = "EndWork", Out = Out, Report = Move.Report }
	end
	if Result.Kind == "Nil" then
		return AnswerCancel(State, Out, Note.ProbeReport, Commands)
	end
	local Landed = Value.DecodeValue(Result.Value, Setup.Build, Setup.Limits.WindowUnit)
	if Landed == nil then
		return EndRead(Commands, Out, UnresolvedAnswer)
	end
	if Landed.Kind == "Sealed" then
		return MissingNext(Out, Commands)
	end
	return ShowKept(State, Setup, Out, Landed, Context, Commands)
end

return {
	TookAnswer = TookAnswer,
	UnresolvedAnswer = UnresolvedAnswer,
	IsHanded = IsHanded,
	BehindAnswer = BehindAnswer,
	EndRead = EndRead,
	FreshRequest = FreshRequest,
	Start = Start,
	StartWant = StartWant,
	StartLoad = StartLoad,
	Resume = Resume,
	TimeOut = TimeOut,
	ReadAgainLater = ReadAgainLater,
	ShowKept = ShowKept,
	ShowState = ShowState,
	OnReadResult = OnReadResult,
	OnUpdateResult = OnUpdateResult,
}
