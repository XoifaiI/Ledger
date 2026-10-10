--!strict
--!optimize 2

--[=[
	Server: routes the copies' calls and events to their owners (extras sheet E8, E9). A copy read that ended goes to
	its holder or follower. Holders refresh, or stop out of use (Refresh), and followers tick when due, not after the
	close; Peek calls time out at their bound, closing or not. Extras/Server's tables point at the handlers here.

	Return type: A plain table with the handlers of the tables, OnDecoded, OnCopyReads, AdviseErased, NoteRead,
	AnswerOpenUnresolved, OnClock and NextWake.
	Example usage:
		local Soonest = CopiesServer.NextWake(State, Clock)
--]=]

local Composed = require("../../Composed")
local CopyRefresh = require("./Refresh")
local CopyState = require("./State")
local Events = require("../../Events")
local Follow = require("./Follow")
local KeyPath = require("./KeyPath")
local Sorted = require("../../Sorted")
local Tick = require("./Tick")

type Command = Events.Command
type DecodeOutcome = Events.DecodeOutcome
type MemoryFetched = Events.MemoryFetched
type MemoryOutcome = Events.MemoryOutcome
type AdviceGet = CopyState.AdviceGet
type HeaderUpdate = CopyState.HeaderUpdate
type State = Composed.State

local function OnAdviceGet(
	State: State,
	Purpose: AdviceGet,
	_RequestId: number,
	Fetched: MemoryFetched,
	_Fraction: number,
	Clock: number,
	Commands: { Command }
)
	CopyRefresh.OnAdviceHeader(State, Purpose, Fetched, Clock, Commands)
end

local function OnHeaderUpdate(
	State: State,
	Purpose: HeaderUpdate,
	Result: MemoryOutcome,
	Clock: number,
	_Commands: { Command }
)
	CopyRefresh.OnHeaderResult(State, Purpose, Result, Clock)
end

local function OnDecoded(State: State, RequestId: number, Outcome: DecodeOutcome, Clock: number, Commands: { Command })
	local Purposes = State.Extras.Purposes
	local Purpose = Purposes[RequestId]
	if Purpose == nil or Purpose.Kind ~= "Decode" then
		return
	end
	Purposes[RequestId] = nil
	Follow.OnDecoded(State, Purpose, Outcome, Clock, Commands)
end

local function OnCopyReads(State: State, Clock: number, Commands: { Command })
	local CopyReads = State.Extras.CopyReads
	if #CopyReads == 0 then
		return
	end
	State.Extras.CopyReads = {}
	for _, Next in CopyReads do
		if Next.Out.Want.Kind == "Follow" then
			KeyPath.OnKeyShown(State, Next, Clock, Commands)
		else
			CopyRefresh.OnKeyShown(State, Next, Clock, Commands)
		end
	end
end

local function OnClock(State: State, Clock: number, Commands: { Command })
	KeyPath.TimeOut(State, Clock, Commands)
	CopyRefresh.OnClock(State, Clock, Commands)
	for _, Text in Sorted.SortedTexts(State.Extras.Followers) do
		local Follower = State.Extras.Followers[Text]
		if Follow.IsTickDue(State, Follower, Clock) then
			Tick.Begin(State, Follower, Clock, Commands)
		end
	end
end

local function NextWake(State: State, Clock: number): number?
	local Soonest = KeyPath.NextWake(State, Clock)
	if State.Sessions.Shutdown ~= nil then
		return Soonest
	end
	Soonest = Composed.EarliestAfter(Soonest, CopyRefresh.NextAt(State, Clock), Clock)
	for _, Follower in State.Extras.Followers do
		Soonest = Composed.EarliestAfter(Soonest, Follower.NextAt, Clock)
	end
	return Soonest
end

return {
	OnFollow = Follow.OnFollow,
	OnUnfollow = Follow.OnUnfollow,
	OnPeekWithin = KeyPath.OnPeekWithin,
	OnAdviceGet = OnAdviceGet,
	OnHeaderGet = Follow.OnHeader,
	OnPartGet = Follow.OnPart,
	OnPartSet = CopyRefresh.OnPartSet,
	OnHeaderUpdate = OnHeaderUpdate,
	OnDecoded = OnDecoded,
	OnCopyReads = OnCopyReads,
	AdviseErased = CopyRefresh.AdviseErased,
	NoteRead = KeyPath.NoteRead,
	AnswerOpenUnresolved = KeyPath.AnswerOpenUnresolved,
	OnClock = OnClock,
	NextWake = NextWake,
}
