--!strict
--!optimize 2

--[=[
	AfterAnswer: how a Tx call answers took or a no that aborts, and what it does once it has answered (transaction
	sheets 15.5, 3.5, 3.7). It resolves each leg key by a ride, a fold into a save, or a request of its own; a ride
	still held FoldWindow on goes alone. Once every resolve ended it holds the drop for HoldDrop. RideEnded counts
	only the Resolve of the batch it sends. A took answer records the part and value that took, then resolves that
	sub name's commit: the call's own, or a sibling's when the step was served. A step that may hold marks of its own
	(OwnMarksStanding) ends them before it ends: it fences its own part unless that is done, reads that fence's
	report, and sends the aborts.

	Return type: A plain table with AnswerOwnTook, AnswerSiblingTook, AbortWith, AbortCall, AbortRefused,
	SendAbortResolves, EndAnsweredCall, AfterCleaningFence, SendRidesDue, AfterResolves and RideEnded.
	Example usage:
		AfterAnswer.AbortCall(State, Call, Reasons.Spent, Clock, Commands)
--]=]

local Cache = require("../../../Keys/DataStore/Cache")
local Closing = require("../../../Keys/DataStore/Closing")
local Composed = require("../../../Shared/Composed")
local Ends = require("../../../Keys/Trades/Ends")
local Events = require("../../../Shared/Events")
local Fates = require("../../../Keys/Format/Items/Fates")
local Lookup = require("../../../Keys/Format/Lookup")
local Names = require("../../../Keys/Encoding/Names")
local Reasons = require("../../../Keys/Constants/Reasons")
local Replies = require("../../../Shared/Replies")
local Requests = require("./Requests")
local Rides = require("../Rides")
local Shapes = require("../../../Shared/Shapes")
local TentReports = require("./TentReports")
local TxShapes = require("../../../Shared/TradeShapes")
local TxCalls = require("./Call")
local TxState = require("../State")
local Writers = require("../../../Keys/DataStore/Writer")

type Command = Events.Command
type GivenAnswer = Events.Answer
type Outcome = Events.Outcome
type Fate = Fates.Fate
type OpName = Names.OpName
type StoreKey = Names.StoreKey
type DropEnd = TxShapes.DropEnd
type Finished = Rides.Finished
type TxOutcome = TxShapes.TxOutcome
type Reason = Reasons.Reason
type ServerState = Shapes.ServerState
type State = Composed.State
type Call = TxState.Call
type Purpose = TxState.Purpose
type Refusal = TentReports.Refusal
type Resolving = TxState.Resolving

type DeciderRefusal = { read Fate: Fate, read State: unknown }

type Took = {
	read Name: OpName,
	read Decider: StoreKey,
	read Attempt: number,
	read Value: number?,
}

local OwnMarksStanding = TxState.OwnMarksStanding

local ErrorReports: { [string]: boolean } = {
	Unreadable = true,
	Missing = true,
	Behind = true,
	NoRoom = true,
}

local RoutingFault = "AfterAnswer: this call is never made."
local NotResolving = `{RoutingFault} A resolve is heard only by a call that sent them.`

local function IsNeeded(Call: Call, Resolving: Resolving, Key: StoreKey): boolean
	local Text = Names.KeyText(Key)
	if Resolving.Outcome == "Commit" then
		local Report = Call.TentReports[Text]
		return Report == nil or Report.Kind ~= "Served"
	end
	return Call.MayHoldMark[Text] == true
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
	Requests.Issue(State, Call, Ends.EndsRequest({ Requests.ResolveEnd(Call, Key, Resolving) }), Purpose, Commands)
end

local function HoldDrop(State: State, Call: Call, Resolving: Resolving, Clock: number)
	local Server = State.Server
	local Dropped: TxShapes.DroppedName = { Name = Resolving.Name, Stamp = Call.Stamp, Proved = nil }
	local Drop: DropEnd = { Kind = "Drop", Names = { Dropped } }
	Rides.Hold(Server, Resolving.Decider, Drop, Clock + Requests.LimitsOf(Server, Call).HoldDrop)
end

local function SendResolves(State: State, Call: Call, Resolving: Resolving, Clock: number, Commands: { Command })
	local Server = State.Server
	Call.Phase = "Resolving"
	Call.Resolving = Resolving
	for _, Key in Call.OtherKeys do
		if not IsNeeded(Call, Resolving, Key) then
			continue
		end
		if Cache.FindStore(Server, Key) == nil then
			Resolving.HasUnresolved = true
			continue
		end
		Resolving.Left += 1
		if CanRide(State, Key) or CanFold(State, Call, Key, Clock) then
			Rides.AddForCall(Server, Key, Requests.ResolveEnd(Call, Key, Resolving), Call.CallId)
			Resolving.RidesDueAt = Clock + Requests.LimitsOf(Server, Call).FoldWindow
		else
			SendResolve(State, Call, Resolving, Key, Clock, Commands)
		end
	end
end

local function HasNoResolveLeft(Resolving: Resolving): boolean
	return Resolving.Left == 0
end

local function NewResolving(
	Name: OpName,
	Decider: StoreKey,
	Outcome: TxOutcome,
	Attempt: number,
	DeciderValue: number?
): Resolving
	return {
		Name = Name,
		Decider = Decider,
		Outcome = Outcome,
		Attempt = Attempt,
		DeciderValue = DeciderValue,
		Left = 0,
		HasUnresolved = false,
	}
end

local function NewAbortResolving(Call: Call): Resolving
	return NewResolving(Call.Name, Call.Decider, "Abort", Call.Attempt, nil)
end

local function SendCleaningFence(State: State, Call: Call, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	Call.Phase = "CleaningFence"
	local Purpose: Purpose = { Kind = "CleaningFence", CallId = Call.CallId, Key = Call.Decider }
	Requests.Issue(State, Call, Requests.FenceRequest(Call, true), Purpose, Commands)
end

local function EndAnsweredCall(State: State, Call: Call, Clock: number, Commands: { Command })
	local Standing = Call.OwnMarksStanding
	Call.OwnMarksStanding = nil
	if Standing == OwnMarksStanding.OwnPartUnfenced then
		return SendCleaningFence(State, Call, Clock, Commands)
	end
	if Standing == nil then
		return TxCalls.End(State, Call, Commands)
	end
	local Aborting = NewAbortResolving(Call)
	SendResolves(State, Call, Aborting, Clock, Commands)
	if HasNoResolveLeft(Aborting) then
		TxCalls.End(State, Call, Commands)
	end
end

local function Finish(State: State, Call: Call, Resolving: Resolving, Clock: number, Commands: { Command })
	if Resolving.Outcome == "Commit" and not Resolving.HasUnresolved then
		HoldDrop(State, Call, Resolving, Clock)
	end
	EndAnsweredCall(State, Call, Clock, Commands)
end

local function StartResolves(State: State, Call: Call, Resolving: Resolving, Clock: number, Commands: { Command })
	SendResolves(State, Call, Resolving, Clock, Commands)
	if HasNoResolveLeft(Resolving) then
		Finish(State, Call, Resolving, Clock, Commands)
	end
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
	if End.Kind ~= "Resolve" or not Lookup.IsSameOp(End.Name, Resolving.Name) then
		return false
	end
	local Text = Names.KeyText(Ride.Key)
	for _, Key in Call.OtherKeys do
		if Names.KeyText(Key) == Text and IsNeeded(Call, Resolving, Key) then
			return true
		end
	end
	return false
end

local function AnswerTook(State: State, Call: Call, Took: Took, Clock: number, Commands: { Command })
	Call.TookPart = Took.Name.Part
	Call.TookValue = Took.Value
	TxCalls.AnswerTrue(Call, Commands)
	local Resolving = NewResolving(Took.Name, Took.Decider, "Commit", Took.Attempt, Took.Value)
	StartResolves(State, Call, Resolving, Clock, Commands)
end

local function AnswerOwnTook(
	State: State,
	Call: Call,
	Attempt: number,
	DeciderValue: number?,
	Clock: number,
	Commands: { Command }
)
	local Took: Took = { Name = Call.Name, Decider = Call.Decider, Attempt = Attempt, Value = DeciderValue }
	AnswerTook(State, Call, Took, Clock, Commands)
end

local function AnswerSiblingTook(
	State: State,
	Call: Call,
	Part: number,
	Attempt: number,
	DeciderValue: number?,
	Clock: number,
	Commands: { Command }
)
	local Took: Took = {
		Name = Names.WithPart(Call.Name, Part),
		Decider = Requests.SiblingKeyOf(Call, Part),
		Attempt = Attempt,
		Value = DeciderValue,
	}
	AnswerTook(State, Call, Took, Clock, Commands)
end

local function SendAbortResolves(State: State, Call: Call, Clock: number, Commands: { Command })
	StartResolves(State, Call, NewAbortResolving(Call), Clock, Commands)
end

local function AbortWith(State: State, Call: Call, Given: GivenAnswer, Clock: number, Commands: { Command })
	TxCalls.Answer(Call, Given, Commands)
	SendAbortResolves(State, Call, Clock, Commands)
end

local function AbortCall(State: State, Call: Call, Why: Reason, Clock: number, Commands: { Command })
	AbortWith(State, Call, Replies.FailedAnswer(Why), Clock, Commands)
end

local function AbortRefused(State: State, Call: Call, Refused: DeciderRefusal, Clock: number, Commands: { Command })
	Call.DeciderFate = Refused.Fate
	local Refusal: Refusal = { Key = Call.Decider, Fate = Refused.Fate, State = Refused.State }
	AbortWith(State, Call, TentReports.RefusalAnswer(Refusal), Clock, Commands)
end

local function AfterCleaningFence(State: State, Call: Call, Result: Outcome, Clock: number, Commands: { Command })
	local Report = Requests.LearnFromAnswer(State, Call, Call.Decider, Result, Commands)
	if Report == nil then
		if Requests.IsResendDue(State.Server, Call, Call.Decider) then
			return SendCleaningFence(State, Call, Clock, Commands)
		end
		return TxCalls.End(State, Call, Commands)
	end
	if Report.Kind == "Fenced" or Report.Kind == "Refused" or Report.Kind == "Forgotten" then
		return SendAbortResolves(State, Call, Clock, Commands)
	end
	TxCalls.End(State, Call, Commands)
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
		if Rides.TakeBack(State.Server, Key, Call.CallId, Resolving.Name) then
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
	AnswerOwnTook = AnswerOwnTook,
	AnswerSiblingTook = AnswerSiblingTook,
	AbortWith = AbortWith,
	AbortCall = AbortCall,
	AbortRefused = AbortRefused,
	SendAbortResolves = SendAbortResolves,
	EndAnsweredCall = EndAnsweredCall,
	AfterCleaningFence = AfterCleaningFence,
	SendRidesDue = SendRidesDue,
	AfterResolves = AfterResolves,
	RideEnded = RideEnded,
}
