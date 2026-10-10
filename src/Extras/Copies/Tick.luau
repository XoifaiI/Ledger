--!strict
--!optimize 2

--[=[
	Tick: what Follow and KeyPath share (extras sheet E9): a Follower's tick, run for a followed key's observers, who
	hear a state or Behind, or for one Peek call, which hears how it ends. Ending sets the next tick, or answers the
	call Unresolved if nothing was shown. A tick that begins keeps the key's copy holder in use, and on a key this
	server heard Behind gives Behind and shows no copy.

	Return type: A plain table of functions, and the ShownState type.
	Example usage:
		Tick.Begin(State, Follower, Clock, Commands)
--]=]

local Composed = require("../../Composed")
local CopyState = require("./State")
local Events = require("../../Events")
local Extras = require("../../Constants/Extras")
local ExtrasState = require("../State")
local Items = require("./Items")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Reads = require("../../Reading/Reads")
local Reasons = require("../../Constants/Reasons")
local Replies = require("../../Replies")
local Shapes = require("../../Shapes")
local Showables = require("../../Reading/Showables")
local Shown = require("../../Reading/Shown")
local Value = require("../../Stored/Value")

type Answer = Events.Answer
type Command = Events.Command
type StoreKey = Names.StoreKey
type Fields = Value.Fields
type Follower = CopyState.Follower
type HeaderGet = CopyState.HeaderGet
type Purpose = ExtrasState.Purpose
type ServerState = Shapes.ServerState
type State = Composed.State

export type ShownState = {
	read Writes: number,
	read At: number,
	read State: Fields,
}

local TickFactor = Extras.TickFactor
local TickFirst = Extras.TickFirst
local TickMost = Extras.TickMost

local FollowStream = "Follow"

local function IsLive(State: State, Follower: Follower): boolean
	local Serves = Follower.Serves
	if Serves.Kind == "Call" then
		return State.Extras.Peeks[Serves.CallId] ~= nil
	end
	return State.Extras.Followers[Names.KeyText(Follower.Key)] == Follower and State.Sessions.Shutdown == nil
end

local function Deliver(State: State, Follower: Follower, Given: Answer, Commands: { Command })
	local Serves = Follower.Serves
	if Serves.Kind == "Call" then
		State.Extras.Peeks[Serves.CallId] = nil
		Replies.Reply(Commands, Serves.CallId, Given)
		return
	end
	if Given.Kind == "Failed" and Given.Reason ~= Reasons.Behind then
		return
	end
	local Emission: Command = { Kind = "Emit", Stream = FollowStream, Key = Follower.Key, Value = Given }
	table.insert(Commands, Emission)
end

local function GiveRising(State: State, Follower: Follower, Q: number, Viewed: Fields, Commands: { Command }): boolean
	local Last = Follower.EmittedQ
	if Last ~= nil and Q <= Last then
		return false
	end
	Deliver(State, Follower, { Kind = "Succeeded", Value = Viewed }, Commands)
	Follower.EmittedQ = Q
	return true
end

local function EndAfter(State: State, Follower: Follower, Delay: number, Clock: number, Commands: { Command })
	local Serves = Follower.Serves
	if Serves.Kind == "Subscribers" then
		Follower.NextAt = Clock + Delay
		return
	end
	if State.Extras.Peeks[Serves.CallId] ~= nil then
		Deliver(State, Follower, Reads.UnresolvedAnswer, Commands)
	end
end

local function SetMoved(Follower: Follower)
	Follower.TickEvery = TickFirst
end

local function SetQuiet(Follower: Follower)
	Follower.TickEvery = math.min(Follower.TickEvery * TickFactor, TickMost)
end

local function EndMoved(State: State, Follower: Follower, Clock: number, Commands: { Command })
	SetMoved(Follower)
	EndAfter(State, Follower, Follower.TickEvery, Clock, Commands)
end

local function EndQuiet(State: State, Follower: Follower, Clock: number, Commands: { Command })
	SetQuiet(Follower)
	EndAfter(State, Follower, Follower.TickEvery, Clock, Commands)
end

local function EmitRising(
	State: State,
	Follower: Follower,
	Q: number,
	Viewed: Fields,
	Clock: number,
	Commands: { Command }
)
	if not GiveRising(State, Follower, Q, Viewed, Commands) then
		return EndQuiet(State, Follower, Clock, Commands)
	end
	EndMoved(State, Follower, Clock, Commands)
end

local function LastShownOf(Server: ServerState, Key: StoreKey): ShownState?
	local Held = Showables.Find(Server, Key)
	local Largest = Shown.LargestOf(Server, Key)
	local At = Shown.LastShownAt(Server, Key)
	if Held == nil or Largest == nil or At == nil or Held.Writes ~= Largest then
		return nil
	end
	return { Writes = Held.Writes, At = At, State = Held.State }
end

local function EndUnchanged(State: State, Follower: Follower, Clock: number, Commands: { Command })
	local Server = State.Server
	local Held = LastShownOf(Server, Follower.Key)
	if Follower.Serves.Kind == "Subscribers" or Held == nil then
		return EndQuiet(State, Follower, Clock, Commands)
	end
	Shown.ShowCopy(Server, Follower.Key, Held.Writes, nil, Clock, State.Sessions.Open)
	Deliver(State, Follower, { Kind = "Succeeded", Value = Held.State }, Commands)
end

local function SendGet(State: State, HeaderKey: string, ItemKey: string, Purpose: Purpose, Commands: { Command })
	local RequestId = ExtrasState.NewRequest(State.Server, State.Extras, Purpose)
	table.insert(Commands, Items.GetCommand(State.Server.Encoding, HeaderKey, ItemKey, RequestId))
end

local function Begin(State: State, Follower: Follower, Clock: number, Commands: { Command })
	Follower.NextAt = nil
	CopyState.NoteUsed(State.Extras.CopyHolders, Follower.Key, Clock)
	if Numbers.IsKnownBehind(State.Server, Follower.Key) then
		Deliver(State, Follower, Reads.BehindAnswer, Commands)
		return EndQuiet(State, Follower, Clock, Commands)
	end
	local HeaderKey = Items.HeaderKey(State.Server.Encoding, Follower.Key)
	local Purpose: HeaderGet = { Kind = "HeaderGet", Follower = Follower }
	SendGet(State, HeaderKey, HeaderKey, Purpose, Commands)
end

return {
	IsLive = IsLive,
	Deliver = Deliver,
	GiveRising = GiveRising,
	EndAfter = EndAfter,
	SetMoved = SetMoved,
	SetQuiet = SetQuiet,
	EndMoved = EndMoved,
	EndQuiet = EndQuiet,
	EmitRising = EmitRising,
	EndUnchanged = EndUnchanged,
	LastShownOf = LastShownOf,
	SendGet = SendGet,
	Begin = Begin,
}
