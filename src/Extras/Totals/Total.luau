--!strict
--!optimize 2

--[=[
	Total: one Total(total, MaxAge) call over shards or a quantity's parts (sheet E4). A fresh view answers (T1);
	else the item (T2), then the entries it lacks, or all if it is unusable or the breaker open (T4, T5), sharing
	reads out. It answers once, Unresolved at B_op; then tidies, and a taker for an absent, malformed or lapsed
	item.

	Return type: A plain table of functions.
	Example usage:
		Total.Begin(State, Call, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Events = require("../../Events")
local ExtrasShapes = require("../Shapes")
local ExtrasState = require("../State")
local Numbers = require("../../Writing/Numbers")
local Pacing = require("../../Writing/Pacing")
local Pairs = require("./Pairs")
local Reasons = require("../../Constants/Reasons")
local Record = require("../../Constants/Record")
local Refresh = require("./Refresh")
local Replies = require("../../Replies")
local Shapes = require("../../Shapes")
local Sorted = require("../../Sorted")
local Subject = require("./Subject")
local Summary = require("./Summary")
local Tidy = require("../Tidy")

type Command = Events.Command
type MemoryFetched = Events.MemoryFetched
type ReadOutcome = Events.ReadOutcome
type Reason = Reasons.Reason
type ReadRound = ExtrasState.ReadRound
type TotalKeyRead = ExtrasState.TotalKeyRead
type SummaryGet = ExtrasState.SummaryGet
type TotalView = ExtrasState.TotalView
type TotalWork = ExtrasState.TotalWork
type TotalCall = ExtrasShapes.TotalCall
type TotalRef = ExtrasShapes.TotalRef
type ItemRead = Subject.ItemRead
type ServerState = Shapes.ServerState
type State = Composed.State

local SummaryMapPrefix = Record.SummaryMapPrefix

local function BoundOf(Server: ServerState, Call: TotalCall): number
	return Cache.StoreNamed(Server, Call.Store).Setup.Limits.OpBound
end

local function NewRound(Reads: number): ReadRound
	return { Pending = Reads, IsThrottled = false, IsGood = false }
end

local function SendRead(
	State: State,
	Ref: TotalRef,
	Index: number,
	Fraction: number,
	Round: ReadRound,
	Clock: number,
	Commands: { Command }
): number
	local Purpose: TotalKeyRead =
		{ Kind = "TotalKeyRead", Ref = Ref, Index = Index, Fraction = Fraction, Round = Round }
	local RequestId = ExtrasState.NewRequest(State.Server, State.Extras, Purpose)
	Subject.ViewOf(State, Ref).ReadOut[Index] = { RequestId = RequestId, SentAt = Clock }
	local Get: Command = {
		Kind = "Get",
		RequestId = RequestId,
		Target = Subject.KeyOf(Ref, Index),
	}
	table.insert(Commands, Get)
	return RequestId
end

local function ReadKey(
	State: State,
	Ref: TotalRef,
	Index: number,
	Fraction: number,
	Clock: number,
	Commands: { Command }
): number
	return SendRead(State, Ref, Index, Fraction, NewRound(1), Clock, Commands)
end

local function AwaitKeys(State: State, Work: TotalWork, Indexes: { number }, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Call = Work.Call
	local Bound = BoundOf(State.Server, Call)
	local View = Subject.ViewOf(State, Call)
	local ToSend: { number } = {}
	for _, Index in Indexes do
		local Out = View.ReadOut[Index]
		if Out == nil or Clock >= Out.SentAt + Bound then
			table.insert(ToSend, Index)
		else
			Work.Waits[Out.RequestId] = true
		end
	end
	local Round = NewRound(#ToSend)
	for _, Index in ToSend do
		Work.Waits[SendRead(State, Call, Index, Call.Fraction, Round, Clock, Commands)] = true
	end
end

local function ReadSummary(State: State, Ref: TotalRef, Commands: { Command }): number
	local Encoding = State.Server.Encoding
	local Purpose: SummaryGet = { Kind = "SummaryGet", Ref = Ref }
	local RequestId = ExtrasState.NewRequest(State.Server, State.Extras, Purpose)
	local Key = Summary.SummaryKey(Encoding, Ref.Store, Ref.Scope, Ref.Total)
	local Get: Command = {
		Kind = "MemoryGet",
		RequestId = RequestId,
		Map = Summary.MapOf(Encoding, SummaryMapPrefix, Key),
		Key = Key,
	}
	table.insert(Commands, Get)
	return RequestId
end

local function Answer(State: State, Call: TotalCall, Commands: { Command })
	Replies.Reply(Commands, Call.CallId, { Kind = "Succeeded", Value = Subject.Answer(State, Call) })
end

local function RunTaker(State: State, Ref: TotalRef, Clock: number, Commands: { Command })
	local Holder = ExtrasState.HolderOf(State.Extras, Ref.Store, Ref.Scope, Ref.Total, Clock)
	if Refresh.CanStart(State, Holder) then
		Refresh.Start(State, Holder, Commands)
	end
end

local function Finish(State: State, Work: TotalWork, Clock: number, Commands: { Command })
	ExtrasState.EndCall(State.Extras, Work)
	for _, Key in Work.Tidies do
		Tidy.Owe(State, Key, Clock, Work.Call.Fraction)
	end
	if Work.IsTakerOwed then
		RunTaker(State, Work.Call, Clock, Commands)
	end
end

local function Fail(State: State, Work: TotalWork, Why: Reason, Clock: number, Commands: { Command })
	Replies.ReplyFailed(Commands, Work.Call.CallId, Why)
	Finish(State, Work, Clock, Commands)
end

local function Conclude(State: State, Work: TotalWork, Clock: number, Commands: { Command })
	if not Subject.IsComplete(State, Work.Call) then
		return Fail(State, Work, Reasons.Unresolved, Clock, Commands)
	end
	Answer(State, Work.Call, Commands)
	Finish(State, Work, Clock, Commands)
end

local function AllIndexes(KeyCount: number): { number }
	local Indexes: { number } = {}
	for Index = 0, KeyCount - 1 do
		table.insert(Indexes, Index)
	end
	return Indexes
end

local function Down(State: State, Work: TotalWork, Clock: number, Commands: { Command })
	local KeyCount = Work.Call.Total.KeyCount
	if Pairs.HasReadEveryKey(Subject.ViewOf(State, Work.Call), KeyCount, Clock) then
		return Conclude(State, Work, Clock, Commands)
	end
	AwaitKeys(State, Work, AllIndexes(KeyCount), Clock, Commands)
end

local function Begin(State: State, Call: TotalCall, Clock: number, Commands: { Command })
	local Deadline = Clock + BoundOf(State.Server, Call)
	local View = Subject.ViewOf(State, Call)
	ExtrasState.NoteHolderUsed(View, Clock)
	if Subject.IsComplete(State, Call) and Pairs.IsFresh(View, Clock, Call.MaxAge) then
		return Answer(State, Call, Commands)
	end
	local Work = ExtrasState.NewCall(State.Extras, Call, Deadline)
	if Pairs.IsOpen(View, Clock) then
		return Down(State, Work, Clock, Commands)
	end
	Work.Waits[ReadSummary(State, Call, Commands)] = true
end

local function ContinueWith(State: State, Work: TotalWork, Read: ItemRead, Clock: number, Commands: { Command })
	if Read.Kind == "Behind" then
		return Fail(State, Work, Reasons.Behind, Clock, Commands)
	end
	if Read.Kind ~= "Item" then
		return Down(State, Work, Clock, Commands)
	end
	if Subject.IsComplete(State, Work.Call) then
		Subject.ViewOf(State, Work.Call).SeenAt = Clock
		Answer(State, Work.Call, Commands)
		return Finish(State, Work, Clock, Commands)
	end
	AwaitKeys(State, Work, Subject.MissingIndexes(State, Work.Call), Clock, Commands)
end

local function IsTakerWanted(Fetched: MemoryFetched, Read: ItemRead, Clock: number, Fraction: number): boolean
	if Fetched.Kind == "Failed" then
		return false
	end
	if Read.Kind == "Item" then
		return Summary.IsLapsed(Read, Clock, Fraction)
	end
	return Read.Kind == "Missing"
end

local function OnSummaryRead(
	State: State,
	Purpose: SummaryGet,
	RequestId: number,
	Fetched: MemoryFetched,
	Fraction: number,
	Clock: number,
	Commands: { Command }
)
	local Ref = Purpose.Ref
	local View = Subject.ViewOf(State, Ref)
	local Works = ExtrasState.TakeWaits(State.Extras, RequestId)
	if Fetched.Kind == "Failed" then
		Pairs.NoteMiss(View, Clock)
	else
		Pairs.NoteHit(View)
	end
	local Read = Subject.ReadItem(State, Ref, Fetched)
	local IsTakerOwed = IsTakerWanted(Fetched, Read, Clock, Fraction)
	if #Works == 0 and IsTakerOwed then
		RunTaker(State, Ref, Clock, Commands)
	end
	for _, Work in Works do
		Work.IsTakerOwed = IsTakerOwed
		ContinueWith(State, Work, Read, Clock, Commands)
	end
end

local function RoundOutcomeOf(Round: ReadRound): Pacing.RoundOutcome
	if Round.IsThrottled then
		return Pacing.RoundOutcomes.Throttled
	end
	if Round.IsGood then
		return Pacing.RoundOutcomes.Good
	end
	return Pacing.RoundOutcomes.Failed
end

local function EndRead(View: TotalView, Purpose: TotalKeyRead, RequestId: number, Fetched: ReadOutcome)
	local Round = Purpose.Round
	local Out = View.ReadOut[Purpose.Index]
	if Out ~= nil and Out.RequestId == RequestId then
		View.ReadOut[Purpose.Index] = nil
	end
	if Fetched.Kind ~= "Failed" then
		Round.IsGood = true
	elseif Fetched.IsThrottled then
		Round.IsThrottled = true
	end
	Round.Pending -= 1
	if Round.Pending == 0 then
		View.Interval = Pacing.Interval(RoundOutcomeOf(Round), View.Interval)
	end
end

local function OnKeyRead(
	State: State,
	Purpose: TotalKeyRead,
	RequestId: number,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
)
	local Ref = Purpose.Ref
	local Server = State.Server
	local Key = Subject.KeyOf(Ref, Purpose.Index)
	local View = Subject.ViewOf(State, Ref)
	local Kept = Subject.LearnRead(State, Ref, Purpose.Index, Fetched, Clock)
	EndRead(View, Purpose, RequestId, Fetched)
	local Works = ExtrasState.TakeWaits(State.Extras, RequestId)
	if Kept ~= nil and Tidy.IsDue(Kept, Numbers.EntryFor(Server, Key), Clock) then
		if #Works == 0 then
			Tidy.Owe(State, Key, Clock, Purpose.Fraction)
		end
		for _, Work in Works do
			table.insert(Work.Tidies, Key)
		end
	end
	for _, Work in Works do
		if next(Work.Waits) == nil then
			Conclude(State, Work, Clock, Commands)
		end
	end
end

local function TimeOut(State: State, Clock: number, Commands: { Command })
	local Calls = State.Extras.Calls
	for _, Id in Sorted.SortedIds(Calls) do
		if Clock >= Calls[Id].Deadline then
			Fail(State, Calls[Id], Reasons.Unresolved, Clock, Commands)
		end
	end
end

local function AnswerOpenUnresolved(State: State, Clock: number, Commands: { Command })
	local Calls = State.Extras.Calls
	for _, Id in Sorted.SortedIds(Calls) do
		Fail(State, Calls[Id], Reasons.Unresolved, Clock, Commands)
	end
end

local function NextWake(State: State, Clock: number): number?
	local Soonest: number? = nil
	for _, Work in State.Extras.Calls do
		Soonest = Composed.EarliestAfter(Soonest, Work.Deadline, Clock)
	end
	return Soonest
end

return {
	Begin = Begin,
	ReadSummary = ReadSummary,
	ReadKey = ReadKey,
	OnSummaryRead = OnSummaryRead,
	OnKeyRead = OnKeyRead,
	TimeOut = TimeOut,
	AnswerOpenUnresolved = AnswerOpenUnresolved,
	NextWake = NextWake,
}
