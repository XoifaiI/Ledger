--!strict
--!optimize 2

--[=[
	Reports: what a walk does with each report (sheet H6, H12). A part's no, a Tx step's refusing decider or a fence
	moves it on. Took answers true (a hold the note lacks, Unresolved). A no is the report's reason, Busy, SoldOut or
	Short; a take's is named. Closed means nothing was sent, so a walk that heard a step or a fence answers Unresolved.
	Outcomes settles an Unresolved take whose send is still in flight.

	Return type: A plain table with TookAnswer, ShortAnswerOf, OnStepOut, OnTxStep, ResumeWalks, OnFenceResult,
	EndUnresolved and EndAtFenceBound.
	Example usage:
		Reports.OnStepOut(State, Walking, Out, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Entries = require("../../Stored/Entries")
local Events = require("../../Events")
local Fates = require("../../Stored/Items/Fates")
local Fence = require("./Fence")
local Holds = require("../Part/Holds")
local HotShapes = require("../Shapes")
local HotState = require("../State")
local JudgingShapes = require("../../Judging/Shapes")
local Numbers = require("../../Writing/Numbers")
local Part = require("../../Stored/Items/Part")
local Reasons = require("../../Constants/Reasons")
local Replies = require("../../Replies")
local Sending = require("../../Writing/Sending")
local Shapes = require("../../Shapes")
local Sorted = require("../../Sorted")
local StepAnswer = require("../../Tx/Call/StepAnswer")
local Tidy = require("../../Extras/Tidy")
local Verdicts = require("./Verdicts")
local View = require("./View")
local Walk = require("./Walk")

type Answer = Events.Answer
type Command = Events.Command
type Fate = Fates.Fate
type PartReason = Fates.PartReason
type PartTry = HotState.PartTry
type Outcome = Events.Outcome
type HoldHandle = HotShapes.HoldHandle
type Took = HotShapes.Took
type Note = JudgingShapes.Note
type ViewEntry = HotState.ViewEntry
type Reason = Reasons.Reason
type Report = JudgingShapes.Report
type StepOut = Shapes.StepOut
type State = Composed.State
type QuantityView = HotState.QuantityView
type HotWalk = HotState.Walk

local PartReasons = Fates.PartReason

local ModuleName = "Reports"
local RoutingFault = `{ModuleName}: this call is never made.`
local NoFenceOut = `{RoutingFault} A fence result is heard only while the walk has a fence out.`
local LateToWalk = `{RoutingFault} A step heard after its call answered goes to Outcomes, never to a walk.`

local function GivesReason(Tried: PartTry): boolean
	return Tried == PartReasons.Free or Tried == PartReasons.Held or Tried == PartReasons.Holds
end

local function ShortReason(Walking: HotWalk): PartReason
	local ReasonsGiven = 0
	local HoldsRefusals = 0
	local HeldRefusals = 0
	for _, Tried in Walking.Tries do
		if GivesReason(Tried) then
			ReasonsGiven += 1
		end
		if Tried == PartReasons.Holds then
			HoldsRefusals += 1
		end
		if Tried == PartReasons.Held then
			HeldRefusals += 1
		end
	end
	if ReasonsGiven > 0 and HoldsRefusals == ReasonsGiven then
		return PartReasons.Holds
	end
	if HeldRefusals > 0 then
		return PartReasons.Held
	end
	return PartReasons.Free
end

local function FailedAnswer(Reason: Reason): Answer
	return { Kind = "Failed", Reason = Reason, State = nil }
end

local UnresolvedAnswer = Replies.UnresolvedAnswer

local function ShortAnswerOf(Reason: PartReason): Answer
	return { Kind = "Failed", Reason = Reasons.Short, State = nil, ShortReason = Reason }
end

local function ShortAnswer(Walking: HotWalk): Answer
	return ShortAnswerOf(ShortReason(Walking))
end

local function NamedAnswer(Walking: HotWalk, Given: Answer): Answer
	if Walking.Call.Method ~= "Take" then
		return Given
	end
	return Replies.Named(Given, Replies.GivenNameOf(Walking.Name, Walking.Stamp))
end

local function OweTidies(State: State, Walking: HotWalk, Clock: number)
	for _, Key in Walking.Tidies do
		Tidy.Owe(State, Key, Clock, Walking.Call.Fraction)
	end
end

local function EndWalk(State: State, Walking: HotWalk, Given: Answer, Clock: number, Commands: { Command })
	local Call = Walking.Call
	Replies.Reply(Commands, Call.CallId, NamedAnswer(Walking, Given))
	if Call.Method == "Take" and Replies.IsUnresolved(Given) then
		Replies.SettleOutcomeUnresolved(Commands, HotState.CurrentKey(Walking), Call.CallId)
	end
	HotState.EndCall(State.Hot, Call.CallId)
	OweTidies(State, Walking, Clock)
end

local function EndAwaiting(State: State, Walking: HotWalk, Given: Answer, Clock: number, Commands: { Command })
	local Call = Walking.Call
	if Call.Method ~= "Take" then
		return EndWalk(State, Walking, Given, Clock, Commands)
	end
	Replies.Reply(Commands, Call.CallId, NamedAnswer(Walking, Given))
	HotState.EndOwedCall(State.Hot, Call.CallId, HotState.CurrentKey(Walking))
	OweTidies(State, Walking, Clock)
end

local function TookAnswer(Index: number, Fate: Fate): Answer
	local Given: Took = { Part = Index, Value = if Fate.Kind == "TookWith" then Fate.Value else nil }
	return { Kind = "Succeeded", Value = Given }
end

local function HoldAnswer(Walking: HotWalk, Index: number, Fate: Fate, Note: Note): Answer
	local Record = Part.RecordOf(HotState.StateOf(Note))
	local Place = Holds.FindHold(Record, Entries.PlainName(Walking.Name))
	if Place == nil then
		return ShortAnswerOf(PartReasons.Gone)
	end
	local Standing = Record.Holds[Place]
	local Serials: HotShapes.Serials? = nil
	if Fate.Kind == "TookWith" then
		Serials = { First = Fate.Value, Count = Standing.Count }
	end
	local Given: HoldHandle = {
		Id = Standing.Id,
		Part = Index,
		Count = Standing.Count,
		End = Standing.End,
		Serials = Serials,
	}
	return { Kind = "Succeeded", Value = Given }
end

local function Finish(State: State, Walking: HotWalk, Known: QuantityView, Clock: number, Commands: { Command })
	if View.IsSoldOut(Known, Walking.Call.Quantity.Parts) then
		return EndWalk(State, Walking, FailedAnswer(Reasons.SoldOut), Clock, Commands)
	end
	EndWalk(State, Walking, ShortAnswer(Walking), Clock, Commands)
end

local function GoOn(State: State, Walking: HotWalk, Clock: number, Commands: { Command })
	local Call = Walking.Call
	local Known = HotState.ViewOf(State.Hot, Call.Store, Call.Scope, Call.Quantity)
	local Next, IsFence = Walk.NextPart(Walking, Known, Clock)
	if Next == nil then
		return Finish(State, Walking, Known, Clock, Commands)
	end
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	if IsFence then
		Walk.Advance(Walking, Next)
		return Fence.SendFence(State, Walking, Clock, Commands)
	end
	if not Walk.CanSendStep(State, Walking, Next) then
		return EndWalk(State, Walking, FailedAnswer(Reasons.Busy), Clock, Commands)
	end
	Walk.Advance(Walking, Next)
	Walk.SendStep(State, Walking, Clock, Clock, Commands)
end

local function OnTook(State: State, Walking: HotWalk, Fate: Fate, Note: Note, Clock: number, Commands: { Command })
	local Index = HotState.CurrentPart(Walking)
	if Walking.Call.Method == "Take" then
		return EndWalk(State, Walking, TookAnswer(Index, Fate), Clock, Commands)
	end
	EndWalk(State, Walking, HoldAnswer(Walking, Index, Fate, Note), Clock, Commands)
end

local function NoteTry(State: State, Walking: HotWalk, Reason: PartReason, Shown: ViewEntry, Clock: number)
	local Call = Walking.Call
	local Known = HotState.ViewOf(State.Hot, Call.Store, Call.Scope, Call.Quantity)
	Walk.NoteRefused(Walking, Reason)
	View.NoteNo(Known, HotState.CurrentPart(Walking), Reason, Call.Count, Clock, Shown)
end

local function OnRefused(
	State: State,
	Walking: HotWalk,
	Reason: PartReason,
	Note: Note,
	Clock: number,
	Commands: { Command }
)
	NoteTry(State, Walking, Reason, View.EntryOfState(Note.Writes, HotState.StateOf(Note)), Clock)
	GoOn(State, Walking, Clock, Commands)
end

local function KnownEntry(State: State, Walking: HotWalk): ViewEntry
	local Call = Walking.Call
	local Known = HotState.ViewOf(State.Hot, Call.Store, Call.Scope, Call.Quantity)
	return View.EntryKnown(Known, HotState.CurrentPart(Walking))
end

local function OnFenceReport(
	State: State,
	Walking: HotWalk,
	Report: Report,
	Note: Note,
	Clock: number,
	Commands: { Command }
)
	local Heard = Verdicts.FenceVerdict(Report)
	if Heard.Kind == "Fenced" then
		Walk.NoteFenced(Walking)
		return GoOn(State, Walking, Clock, Commands)
	end
	if Heard.Kind == "Took" then
		return OnTook(State, Walking, Heard.Fate, Note, Clock, Commands)
	end
	if Heard.Kind == "Refused" then
		return OnRefused(State, Walking, Heard.Reason, Note, Clock, Commands)
	end
	EndWalk(State, Walking, Heard.Given, Clock, Commands)
end

local function OnFenceResult(State: State, Walking: HotWalk, Result: Outcome, Clock: number, Commands: { Command })
	local Sent = Walking.Fence
	if Sent == nil then
		error(NoFenceOut)
	end
	local Server = State.Server
	local Key = HotState.CurrentKey(Walking)
	local Setup = Cache.StoreOf(Server, Key).Setup
	if Result.Kind == "Err" then
		Sent.Errors += 1
		if Sent.Errors >= Setup.Limits.ErrorsBeforeUnresolved then
			return EndWalk(State, Walking, UnresolvedAnswer, Clock, Commands)
		end
		Sent.RetryAt = Clock + Sending.RetryGap(Sent.Errors, Setup.Limits)
		return
	end
	local Note = Result.Note
	Numbers.LearnFromNote(Server, Numbers.EntryFor(Server, Key), Key, Setup, Note)
	Sending.WarnFromNote(Key, Note, Commands)
	OnFenceReport(State, Walking, Note.EndReports[1], Note, Clock, Commands)
end

local function EndUnresolved(State: State, Walking: HotWalk, Clock: number, Commands: { Command })
	EndWalk(State, Walking, UnresolvedAnswer, Clock, Commands)
end

local function EndReading(State: State, Walking: HotWalk, Reason: Reason, Clock: number, Commands: { Command })
	EndWalk(State, Walking, FailedAnswer(Reason), Clock, Commands)
end

local function AfterPartRead(State: State, Walking: HotWalk, IsRead: boolean, Clock: number, Commands: { Command })
	if not IsRead then
		return EndReading(State, Walking, Reasons.Busy, Clock, Commands)
	end
	local Call = Walking.Call
	local Known = HotState.ViewOf(State.Hot, Call.Store, Call.Scope, Call.Quantity)
	if View.IsAbsentNow(Known, Walking.Order[1], Clock) then
		return EndReading(State, Walking, Reasons.Missing, Clock, Commands)
	end
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return EndReading(State, Walking, Reasons.Closed, Clock, Commands)
	end
	Walk.BeginAfterRead(State, Walking, Clock, Commands)
end

local function EndAtFenceBound(State: State, Walking: HotWalk, Clock: number, Commands: { Command })
	local Sent = Walking.Fence
	if Sent ~= nil and Sent.RetryAt == nil then
		return EndAwaiting(State, Walking, UnresolvedAnswer, Clock, Commands)
	end
	EndUnresolved(State, Walking, Clock, Commands)
end

local function OpenTxStepOf(State: State, Walking: HotWalk): number?
	local StepId = Walking.TxStepId
	if StepId == nil or not StepAnswer.IsOpen(State, StepId) then
		return nil
	end
	return StepId
end

local function FollowTxStep(State: State, Walking: HotWalk, StepId: number)
	StepAnswer.Follow(State, StepId)
	HotState.AddTxStep(State.Hot, StepId, { Kind = "Walk", CallId = Walking.Call.CallId })
end

local function OnTxStep(
	State: State,
	Walking: HotWalk,
	Taken: StepAnswer.StepAnswer,
	Clock: number,
	Commands: { Command }
)
	local Heard = Verdicts.TxStepVerdict(Taken)
	if Heard.Kind == "Took" then
		return EndWalk(State, Walking, TookAnswer(HotState.CurrentPart(Walking), Heard.Fate), Clock, Commands)
	end
	if Heard.Kind == "Refused" then
		NoteTry(State, Walking, Heard.Reason, KnownEntry(State, Walking), Clock)
		return Walk.NoteTxStepHeard(Walking, Clock)
	end
	if Heard.Kind == "Fenced" then
		Walk.NoteFenced(Walking)
		return Walk.NoteTxStepHeard(Walking, Clock)
	end
	local OpenStepId = OpenTxStepOf(State, Walking)
	if Replies.IsUnresolved(Heard.Given) and OpenStepId ~= nil then
		FollowTxStep(State, Walking, OpenStepId)
		return EndAwaiting(State, Walking, Heard.Given, Clock, Commands)
	end
	EndWalk(State, Walking, Heard.Given, Clock, Commands)
end

local function ResumeWalks(State: State, Clock: number, Commands: { Command }): boolean
	local IsResumed = false
	for _, CallId in Sorted.SortedIds(State.Hot.Walks) do
		local Walking = State.Hot.Walks[CallId]
		if Walk.TakeClosedTxStep(State, Walking) then
			GoOn(State, Walking, Clock, Commands)
			IsResumed = true
		end
	end
	return IsResumed
end

local function HasSent(Walking: HotWalk): boolean
	return next(Walking.Tries) ~= nil or Walking.HasFencedStep
end

local function OnStepOut(State: State, Walking: HotWalk, Out: StepOut, Clock: number, Commands: { Command })
	if Out.Kind == "Late" then
		error(LateToWalk)
	end
	if Out.Kind == "Answered" then
		if Out.Reason == Reasons.Unresolved and not Closing.IsEnded(State.Sessions) then
			return EndAwaiting(State, Walking, UnresolvedAnswer, Clock, Commands)
		end
		if Out.Reason == Reasons.Closed and HasSent(Walking) then
			return EndWalk(State, Walking, UnresolvedAnswer, Clock, Commands)
		end
		return EndWalk(State, Walking, FailedAnswer(Out.Reason), Clock, Commands)
	end
	local Heard = Verdicts.StepVerdict(Out.Reason, Out.Report)
	if Heard.Kind == "Took" then
		return OnTook(State, Walking, Heard.Fate, Out.Note, Clock, Commands)
	end
	if Heard.Kind == "Refused" then
		return OnRefused(State, Walking, Heard.Reason, Out.Note, Clock, Commands)
	end
	if Heard.Kind == "Fenced" then
		Walk.NoteStepFenced(Walking)
		return GoOn(State, Walking, Clock, Commands)
	end
	EndWalk(State, Walking, Heard.Given, Clock, Commands)
end

return {
	TookAnswer = TookAnswer,
	ShortAnswerOf = ShortAnswerOf,
	OnStepOut = OnStepOut,
	OnTxStep = OnTxStep,
	ResumeWalks = ResumeWalks,
	OnFenceResult = OnFenceResult,
	EndUnresolved = EndUnresolved,
	EndReading = EndReading,
	AfterPartRead = AfterPartRead,
	EndAtFenceBound = EndAtFenceBound,
}
