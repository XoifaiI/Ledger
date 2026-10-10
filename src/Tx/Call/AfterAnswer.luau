--!strict
--!optimize 2

--[=[
	AfterAnswer: what a Tx call does once it has answered (transaction sheets 15.5, 3.5, 3.7). It resolves each leg
	key by a ride, a fold into a save, or a request of its own; a ride still held FoldWindow on goes alone. Once
	every resolve ended it holds the drop for HoldDrop. RideEnded counts only the call's own Resolve.

	Return type: A plain table with SendCommitResolves, SendAbortResolves, SendRidesDue, AfterResolves and RideEnded.
	Example usage:
		AfterAnswer.SendAbortResolves(State, Call, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Ends = require("../Legs/Ends")
local Events = require("../../Events")
local Lookup = require("../../Stored/Lookup")
local Names = require("../../Encoding/Names")
local Requests = require("./Requests")
local Rides = require("../Rides")
local Shapes = require("../../Shapes")
local TxShapes = require("../Shapes")
local TxCalls = require("./Call")
local TxState = require("../State")
local Writers = require("../../Writing/Writer")

type Command = Events.Command
type Outcome = Events.Outcome
type OpName = Names.OpName
type StoreKey = Names.StoreKey
type DropEnd = TxShapes.DropEnd
type Finished = Rides.Finished
type ResolveEnd = TxShapes.ResolveEnd
type TxOutcome = TxShapes.TxOutcome
type ServerState = Shapes.ServerState
type State = Composed.State
type Call = TxState.Call
type Purpose = TxState.Purpose
type Resolving = TxState.Resolving

local ErrorReports: { [string]: boolean } = {
	Unreadable = true,
	Missing = true,
	Behind = true,
	NoRoom = true,
}

local RoutingFault = "AfterAnswer: this call is never made."
local NotResolving = `{RoutingFault} A resolve is heard only by a call that sent them.`

local function IsNeeded(Call: Call, Outcome: TxOutcome, Key: StoreKey): boolean
	return Outcome == "Commit" or Call.MayHoldMark[Names.KeyText(Key)] == true
end

local function HoldsUnsentOp(Server: ServerState, Key: StoreKey): boolean
	local Writer = Writers.WriterFor(Server, Key)
	if Writer == nil then
		return false
	end
	for _, Op in Writer.Queue do
		if not Op.IsSent and not Op.IsHeard then
			return true
		end
	end
	return false
end

local function CanRide(State: State, Key: StoreKey): boolean
	return State.Sessions.Open[Names.KeyText(Key)] == nil and HoldsUnsentOp(State.Server, Key)
end

local function CanFold(State: State, Call: Call, Key: StoreKey, Clock: number): boolean
	local Text = Names.KeyText(Key)
	local Open = State.Sessions.Open[Text]
	if Open == nil or Call.OtherMarkOn[Text] ~= false or not HoldsUnsentOp(State.Server, Key) then
		return false
	end
	local Limits = Cache.StoreOf(State.Server, Key).Setup.Limits
	return Open.PushedAt + Limits.SaveInterval - Clock <= Limits.FoldWindow
end

local function EndOf(Call: Call, Resolving: Resolving, Key: StoreKey): ResolveEnd
	return Requests.ResolveEnd(Call, Key, Resolving.Outcome, Resolving.Attempt, Resolving.DeciderValue)
end

local function SendResolve(
	State: State,
	Call: Call,
	Resolving: Resolving,
	Key: StoreKey,
	Clock: number,
	Commands: { Command }
)
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Purpose: Purpose = { Kind = "Resolve", CallId = Call.CallId, Key = Key }
	Requests.Issue(State, Call, Ends.EndsRequest({ EndOf(Call, Resolving, Key) }), Purpose, Commands)
end

local function HoldDrop(State: State, Call: Call, Clock: number)
	local Server = State.Server
	local Dropped: TxShapes.DroppedName = { Name = Call.Name, Stamp = Call.Stamp, Proved = nil }
	local Drop: DropEnd = { Kind = "Drop", Names = { Dropped } }
	Rides.Hold(Server, Call.Decider, Drop, Clock + Requests.LimitsOf(Server, Call).HoldDrop)
end

local function Finish(State: State, Call: Call, Resolving: Resolving, Clock: number, Commands: { Command })
	if Resolving.Outcome == "Commit" and not Resolving.HasUnresolved then
		HoldDrop(State, Call, Clock)
	end
	TxCalls.End(State, Call, Commands)
end

local function ResolveEnded(
	State: State,
	Call: Call,
	Resolving: Resolving,
	IsDone: boolean,
	Clock: number,
	Commands: { Command }
)
	Resolving.Left -= 1
	if not IsDone then
		Resolving.HasUnresolved = true
	end
	if Resolving.Left == 0 then
		Finish(State, Call, Resolving, Clock, Commands)
	end
end

local function IsOwnResolve(Call: Call, Resolving: Resolving, Ride: Finished): boolean
	local End = Ride.End
	if End.Kind ~= "Resolve" or not Lookup.IsSameOp(End.Name, Call.Name) then
		return false
	end
	local Text = Names.KeyText(Ride.Key)
	for _, Key in Call.OtherKeys do
		if Names.KeyText(Key) == Text and IsNeeded(Call, Resolving.Outcome, Key) then
			return true
		end
	end
	return false
end

local function SendResolves(State: State, Call: Call, Resolving: Resolving, Clock: number, Commands: { Command })
	local Server = State.Server
	Call.Phase = "Resolving"
	Call.Resolving = Resolving
	for _, Key in Call.OtherKeys do
		if not IsNeeded(Call, Resolving.Outcome, Key) then
			continue
		end
		if Cache.FindStore(Server, Key) == nil then
			Resolving.HasUnresolved = true
			continue
		end
		Resolving.Left += 1
		if CanRide(State, Key) or CanFold(State, Call, Key, Clock) then
			Rides.AddForCall(Server, Key, EndOf(Call, Resolving, Key), Call.CallId)
			Resolving.RidesDueAt = Clock + Requests.LimitsOf(Server, Call).FoldWindow
		else
			SendResolve(State, Call, Resolving, Key, Clock, Commands)
		end
	end
	if Resolving.Left == 0 then
		Finish(State, Call, Resolving, Clock, Commands)
	end
end

local function SendCommitResolves(
	State: State,
	Call: Call,
	Attempt: number,
	DeciderValue: number?,
	Clock: number,
	Commands: { Command }
)
	local Resolving: Resolving = {
		Outcome = "Commit",
		Attempt = Attempt,
		DeciderValue = DeciderValue,
		Left = 0,
		HasUnresolved = false,
	}
	SendResolves(State, Call, Resolving, Clock, Commands)
end

local function SendAbortResolves(State: State, Call: Call, Clock: number, Commands: { Command })
	local Resolving: Resolving = { Outcome = "Abort", Attempt = Call.Attempt, Left = 0, HasUnresolved = false }
	SendResolves(State, Call, Resolving, Clock, Commands)
end

local function SendRidesDue(State: State, Call: Call, Clock: number, Commands: { Command })
	local Resolving = Call.Resolving
	if Call.Phase ~= "Resolving" or Resolving == nil or Resolving.RidesDueAt == nil then
		return
	end
	if Clock < Resolving.RidesDueAt or Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	Resolving.RidesDueAt = nil
	for _, Key in Call.OtherKeys do
		if Rides.TakeBack(State.Server, Key, Call.CallId, Call.Name) then
			SendResolve(State, Call, Resolving, Key, Clock, Commands)
		end
	end
end

local function AfterResolves(
	State: State,
	Call: Call,
	Key: StoreKey,
	Result: Outcome,
	Clock: number,
	Commands: { Command }
)
	local Resolving = Call.Resolving
	if Resolving == nil then
		error(NotResolving)
	end
	local Report = Requests.LearnFromAnswer(State, Call, Key, Result, Commands)
	if Report == nil and Requests.IsResendDue(State.Server, Call, Key) then
		return SendResolve(State, Call, Resolving, Key, Clock, Commands)
	end
	ResolveEnded(State, Call, Resolving, Report ~= nil and Report.Kind == "Done", Clock, Commands)
end

local function RideEnded(State: State, Call: Call, Ride: Finished, Clock: number, Commands: { Command })
	local Resolving = Call.Resolving
	if Resolving == nil or not IsOwnResolve(Call, Resolving, Ride) then
		return
	end
	if ErrorReports[Ride.Report.Kind] == true then
		Requests.MarkErred(Call, Names.KeyText(Ride.Key))
		if Requests.IsResendDue(State.Server, Call, Ride.Key) then
			return SendResolve(State, Call, Resolving, Ride.Key, Clock, Commands)
		end
		return ResolveEnded(State, Call, Resolving, false, Clock, Commands)
	end
	ResolveEnded(State, Call, Resolving, Ride.Report.Kind == "Done", Clock, Commands)
end

return {
	SendCommitResolves = SendCommitResolves,
	SendAbortResolves = SendAbortResolves,
	SendRidesDue = SendRidesDue,
	AfterResolves = AfterResolves,
	RideEnded = RideEnded,
}
