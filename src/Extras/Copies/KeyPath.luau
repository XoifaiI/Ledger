--!strict
--!optimize 2

--[=[
	KeyPath: a follower's key path and Peek(key, MaxAge) (extras sheet E9 F6, F7). A big or newer header, a
	failed header Get or a refused show reads the key through Reads, or ends the tick from the close deadline. A
	MaxAge of 0 is a plain Peek: it never shows a copy or the last shown state.
	FollowEvery spaces the next tick, jittered by the read's fraction, doubled after a throttled read, halved after a
	good one.

	Return type: A plain table of functions.
	Example usage:
		KeyPath.StartKeyRead(State, Follower, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local CopyRefresh = require("./Refresh")
local CopyState = require("./State")
local Events = require("../../Events")
local ExtrasShapes = require("../Shapes")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Pacing = require("../../Writing/Pacing")
local Reads = require("../../Reading/Reads")
local Reasons = require("../../Constants/Reasons")
local Replies = require("../../Replies")
local Sorted = require("../../Sorted")
local Tick = require("./Tick")

type Command = Events.Command
type ReadOutcome = Events.ReadOutcome
type CopyRead = CopyState.CopyRead
type Follower = CopyState.Follower
type PeekWithinCall = ExtrasShapes.PeekWithinCall
type ReadOut = Reads.ReadOut
type State = Composed.State

local FollowWant: Reads.Want = table.freeze({ Kind = "Follow" :: "Follow" })
local PlainPeek: Reads.ReadKind = "Peek"

local function FollowerOfRead(State: State, Out: ReadOut): Follower?
	local Followed = State.Extras.Followers[Names.KeyText(Out.Key)]
	if Followed ~= nil and Followed.KeyCallId == Out.CallId then
		return Followed
	end
	for _, Work in State.Extras.Peeks do
		if Work.Follower.KeyCallId == Out.CallId then
			return Work.Follower
		end
	end
	return nil
end

local function StartKeyRead(State: State, Follower: Follower, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return Tick.EndAfter(State, Follower, Follower.TickEvery, Clock, Commands)
	end
	local Server = State.Server
	local Call = { CallId = Numbers.NewHelperId(Server), Key = Follower.Key }
	local Out = Reads.StartWant(Server, Call, FollowWant, Clock, Commands)
	State.Reads[Out.RequestId] = Out
	Follower.KeyCallId = Call.CallId
	Follower.IsKeyThrottled = false
	Follower.KeyFraction = 0
end

local function NoteRead(State: State, RequestId: number, Fetched: ReadOutcome, Fraction: number)
	local Out = State.Reads[RequestId]
	if Out == nil or Out.Want.Kind ~= "Follow" then
		return
	end
	local Follower = FollowerOfRead(State, Out)
	if Follower == nil then
		return
	end
	Follower.KeyFraction = Fraction
	if Fetched.Kind == "Failed" and Fetched.IsThrottled then
		Follower.IsKeyThrottled = true
	end
end

local function IsUnanswered(Next: CopyRead): boolean
	if Next.Kind ~= "Handed" then
		return false
	end
	local Given = Next.Answer
	return Given.Kind == "Failed" and Given.Reason == Reasons.Unresolved
end

local function RoundOutcomeOf(Follower: Follower, Next: CopyRead): Pacing.RoundOutcome
	if Follower.IsKeyThrottled then
		return Pacing.RoundOutcomes.Throttled
	end
	if IsUnanswered(Next) then
		return Pacing.RoundOutcomes.Failed
	end
	return Pacing.RoundOutcomes.Good
end

local function ShowNext(State: State, Follower: Follower, Next: CopyRead, Clock: number, Commands: { Command }): boolean
	if Next.Kind == "Opened" then
		return Tick.GiveRising(State, Follower, Next.Kept.Book.Writes, Next.Viewed, Commands)
	end
	local Given = Next.Answer
	if Given.Kind == "Failed" and Given.Reason == Reasons.Missing then
		CopyRefresh.RemoveItems(State, Follower.Key, Clock, Commands)
	end
	Tick.Deliver(State, Follower, Given, Commands)
	return false
end

local function OnKeyShown(State: State, Next: CopyRead, Clock: number, Commands: { Command })
	local Follower = FollowerOfRead(State, Next.Out)
	if Follower == nil then
		return
	end
	Follower.KeyCallId = nil
	if not Tick.IsLive(State, Follower) then
		return
	end
	Follower.FollowEvery = Pacing.Interval(RoundOutcomeOf(Follower, Next), Follower.FollowEvery)
	if ShowNext(State, Follower, Next, Clock, Commands) then
		Tick.SetMoved(Follower)
	else
		Tick.SetQuiet(Follower)
	end
	Tick.EndAfter(State, Follower, Follower.FollowEvery * (1 + Follower.KeyFraction), Clock, Commands)
end

local function OnPeekWithin(State: State, Call: PeekWithinCall, _Arrived: number, Clock: number, Commands: { Command })
	local Server = State.Server
	if Call.MaxAge == 0 then
		local Out = Reads.Start(Server, Call, PlainPeek, Clock, Commands)
		State.Reads[Out.RequestId] = Out
		return
	end
	local Held = Tick.LastShownOf(Server, Call.Key)
	if Held ~= nil and Clock - Held.At < Call.MaxAge then
		return Replies.Reply(Commands, Call.CallId, { Kind = "Succeeded", Value = Held.State })
	end
	local Follower = CopyState.NewFollower(Call.Key, { Kind = "Call", CallId = Call.CallId })
	local Deadline = Clock + Cache.StoreOf(Server, Call.Key).Setup.Limits.OpBound
	State.Extras.Peeks[Call.CallId] = { Call = Call, Deadline = Deadline, Follower = Follower }
	Tick.Begin(State, Follower, Clock, Commands)
end

local function TimeOut(State: State, Clock: number, Commands: { Command })
	local Peeks = State.Extras.Peeks
	for _, Id in Sorted.SortedIds(Peeks) do
		if Clock >= Peeks[Id].Deadline then
			Tick.Deliver(State, Peeks[Id].Follower, Reads.UnresolvedAnswer, Commands)
		end
	end
end

local function AnswerOpenUnresolved(State: State, Commands: { Command })
	local Peeks = State.Extras.Peeks
	for _, Id in Sorted.SortedIds(Peeks) do
		Tick.Deliver(State, Peeks[Id].Follower, Reads.UnresolvedAnswer, Commands)
	end
end

local function NextWake(State: State, Clock: number): number?
	local Soonest: number? = nil
	for _, Work in State.Extras.Peeks do
		Soonest = Composed.EarliestAfter(Soonest, Work.Deadline, Clock)
	end
	return Soonest
end

return {
	StartKeyRead = StartKeyRead,
	NoteRead = NoteRead,
	OnKeyShown = OnKeyShown,
	OnPeekWithin = OnPeekWithin,
	TimeOut = TimeOut,
	AnswerOpenUnresolved = AnswerOpenUnresolved,
	NextWake = NextWake,
}
