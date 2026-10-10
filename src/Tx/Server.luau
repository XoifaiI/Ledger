--!strict
--!optimize 2

--[=[
	Server: routes the transaction's events to their owners by State.Tx.Purposes, forgetting a purpose once heard. On
	the clock a call answers Unresolved past OpBound, finishes its gate, sends again and sends a due ride alone. At
	CloseAll a call that sent no write answers Closed; others answer Unresolved, and owed outcomes settle so, once the
	close ends.

	Return type: A plain table with OnCall, OnRead, OnResult, OnCarried, ReleaseRides, OnClock, NextWake,
	QueueDeadline, CloseAll and AfterEvent.
	Example usage:
		if not Server.OnRead(State, RequestId, Fetched, Clock, Commands) then ... end
--]=]

local AfterAnswer = require("./Call/AfterAnswer")
local Cache = require("../Reading/Cache")
local Composed = require("../Composed")
local CutsCall = require("../Cuts/Call/Call")
local Drain = require("../Cuts/Call/Drain")
local Events = require("../Events")
local Help = require("./Work/Help")
local InFlight = require("../Reading/InFlight")
local Names = require("../Encoding/Names")
local NextSteps = require("./Call/NextSteps")
local Operators = require("./Work/Operators")
local Reasons = require("../Constants/Reasons")
local Reports = require("./Call/Reports")
local Rides = require("./Rides")
local Shapes = require("../Shapes")
local Shedding = require("../Writing/Shedding")
local Sorted = require("../Sorted")
local Touch = require("./Work/Touch")
local TxCalls = require("./Call/Call")
local TxShapes = require("./Shapes")
local TxState = require("./State")
local Unclean = require("./Work/Unclean")
local Verify = require("./Work/Verify")

type Command = Events.Command
type GivenAnswer = Events.Answer
type Outcome = Events.Outcome
type PendingCallEvent = Events.PendingCall
type ReadOutcome = Events.ReadOutcome
type ResettleCallEvent = Events.ResettleCall
type TxCallEvent = Events.TxCall
type StoreKey = Names.StoreKey
type End = TxShapes.End
type Finished = Rides.Finished
type ServerState = Shapes.ServerState
type State = Composed.State
type Call = TxState.Call
type Waiter = TxState.Waiter

local ClosedAnswer: GivenAnswer = table.freeze({ Kind = "Failed" :: "Failed", Reason = Reasons.Closed, State = nil })

local function WaitingCall(State: State, Waiter: Waiter): Call?
	if Waiter.Kind ~= "Call" then
		return nil
	end
	return State.Tx.Calls[Waiter.CallId]
end

local function AfterWork(State: State, Waiter: Waiter?, Clock: number, Commands: { Command })
	if Waiter == nil then
		return
	end
	if Waiter.Kind == "Touch" then
		return Touch.AfterWork(State, Waiter.Key, Clock, Commands)
	end
	if Waiter.Kind == "Resettle" then
		return Operators.AfterWork(State, Waiter.CallId, Clock, Commands)
	end
	if Waiter.Kind == "Cut" then
		return CutsCall.AfterWork(State, Waiter.CallId, Clock, Commands)
	end
	local Waiting = WaitingCall(State, Waiter)
	if Waiting ~= nil then
		NextSteps.AfterHelped(State, Waiting, Clock, Commands)
	end
end

local function AfterVerification(State: State, Waiter: Waiter?, Clock: number, Commands: { Command })
	if Waiter == nil then
		return
	end
	if Waiter.Kind == "Help" then
		return AfterWork(State, Help.OnVerified(State, Waiter.HelpId, Clock, Commands), Clock, Commands)
	end
	if Waiter.Kind == "Touch" or Waiter.Kind == "Resettle" then
		return AfterWork(State, Waiter, Clock, Commands)
	end
	if Waiter.Kind == "Cut" then
		return Drain.OnVerified(State, Waiter.CallId, Clock, Commands)
	end
	local Waiting = WaitingCall(State, Waiter)
	if Waiting ~= nil then
		NextSteps.AfterVerified(State, Waiting, Clock, Commands)
	end
end

local function OnCall(
	State: State,
	Event: TxCallEvent | PendingCallEvent | ResettleCallEvent,
	Arrived: number,
	Clock: number,
	Commands: { Command }
)
	if Event.Method == "Tx" then
		return TxCalls.Begin(State, Event, Arrived, Clock, Commands)
	end
	if Event.Method == "Pending" then
		return Operators.StartPending(State, Event, Arrived, Commands)
	end
	Operators.StartResettle(State, Event, Arrived, Commands)
end

local function OnRead(
	State: State,
	RequestId: number,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
): boolean
	local Tx = State.Tx
	local Purpose = Tx.Purposes[RequestId]
	if Purpose == nil then
		return false
	end
	if Purpose.Kind == "IncarnationRead" then
		Tx.Purposes[RequestId] = nil
		local Pending = Tx.PendingCalls[Purpose.CallId]
		if Pending ~= nil then
			TxCalls.OnIncarnationRead(State, Pending, Purpose.Key, Fetched, Clock, Commands)
		end
		return true
	end
	if Purpose.Kind == "RetryRead" then
		Tx.Purposes[RequestId] = nil
		local Reading = Tx.Calls[Purpose.CallId]
		if Reading ~= nil then
			Reports.AfterRetryRead(State, Reading, Fetched, Clock, Commands)
		end
		return true
	end
	if Purpose.Kind == "HelpRead" then
		Tx.Purposes[RequestId] = nil
		local Helping = Tx.Helps[Purpose.HelpId]
		if Helping ~= nil then
			AfterWork(
				State,
				Help.OnDeciderRead(State, Helping, Purpose.Blocker, Fetched, Clock, Commands),
				Clock,
				Commands
			)
		end
		return true
	end
	if Purpose.Kind == "VerifyRead" then
		Tx.Purposes[RequestId] = nil
		local Verification = Tx.Verifies[Purpose.VerifyId]
		if Verification ~= nil then
			local Waiter = Verify.OnRead(State, Verification, Purpose.Record, Purpose.Key, Fetched, Clock, Commands)
			AfterVerification(State, Waiter, Clock, Commands)
		end
		return true
	end
	if Purpose.Kind == "TouchRead" then
		Tx.Purposes[RequestId] = nil
		Touch.OnTouchRead(State, Purpose.Key, Fetched, Clock)
		return true
	end
	if Purpose.Kind == "UncleanRead" then
		Tx.Purposes[RequestId] = nil
		local Next = Unclean.OnUncleanRead(State, Purpose, Fetched, Clock, Commands)
		InFlight.ActOnNext(State, Next, Clock, Commands)
		return true
	end
	if Purpose.Kind == "PendingRead" then
		Tx.Purposes[RequestId] = nil
		Operators.Pending(State, Purpose, Fetched, Clock, Commands)
		return true
	end
	if Purpose.Kind == "ResettleRead" then
		Tx.Purposes[RequestId] = nil
		local Resettling = Tx.Resettles[Purpose.CallId]
		if Resettling ~= nil then
			Operators.AfterResettleRead(State, Resettling, Fetched, Clock, Commands)
		end
		return true
	end
	return false
end

local function OnCarried(State: State, Finished: { Finished }, Clock: number, Commands: { Command })
	for _, Ride in Finished do
		local Waiting = State.Tx.Calls[Ride.CallId]
		if Waiting ~= nil then
			AfterAnswer.RideEnded(State, Waiting, Ride, Clock, Commands)
		end
	end
end

local function ReleaseRides(
	State: State,
	Key: StoreKey,
	Carried: { End },
	Result: Outcome,
	Clock: number,
	Commands: { Command }
)
	if Result.Kind ~= "Err" then
		local Finished = Rides.Heard(State.Server, Key, Carried, Result.Note)
		OnCarried(State, Finished, Clock, Commands)
	end
end

local function OnResult(State: State, RequestId: number, Result: Outcome, Clock: number, Commands: { Command }): boolean
	local Tx = State.Tx
	local Purpose = Tx.Purposes[RequestId]
	if Purpose == nil then
		return false
	end
	if Purpose.Kind == "Tent" then
		Tx.Purposes[RequestId] = nil
		ReleaseRides(State, Purpose.Key, Purpose.Carried, Result, Clock, Commands)
		local Telling = Tx.Calls[Purpose.CallId]
		if Telling ~= nil then
			Reports.HearTent(State, Telling, Purpose.Key, Result, Clock, Commands)
		end
		return true
	end
	if Purpose.Kind == "Commit" then
		Tx.Purposes[RequestId] = nil
		ReleaseRides(State, Purpose.Key, Purpose.Carried, Result, Clock, Commands)
		local Committing = Tx.Calls[Purpose.CallId]
		if Committing ~= nil then
			Reports.AfterCommit(State, Committing, Result, Clock, Commands)
		end
		return true
	end
	if Purpose.Kind == "FinalFence" then
		Tx.Purposes[RequestId] = nil
		local Fencing = Tx.Calls[Purpose.CallId]
		if Fencing ~= nil then
			Reports.AfterFinalFence(State, Fencing, Result, Clock, Commands)
		end
		return true
	end
	if Purpose.Kind == "Resolve" then
		Tx.Purposes[RequestId] = nil
		local Answered = Tx.Calls[Purpose.CallId]
		if Answered ~= nil then
			AfterAnswer.AfterResolves(State, Answered, Purpose.Key, Result, Clock, Commands)
		end
		return true
	end
	if Purpose.Kind == "HelpFence" then
		Tx.Purposes[RequestId] = nil
		local Helping = Tx.Helps[Purpose.HelpId]
		if Helping ~= nil then
			AfterWork(
				State,
				Help.OnHelpFence(State, Helping, Purpose.Blocker, Result, Clock, Commands),
				Clock,
				Commands
			)
		end
		return true
	end
	if Purpose.Kind == "VerifyResolve" or Purpose.Kind == "Prove" then
		Tx.Purposes[RequestId] = nil
		local Verification = Tx.Verifies[Purpose.VerifyId]
		if Verification == nil then
			return true
		end
		local Waiter: Waiter?
		if Purpose.Kind == "VerifyResolve" then
			Waiter = Verify.OnResolve(State, Verification, Purpose.Record, Purpose.Key, Result, Clock, Commands)
		else
			Waiter = Verify.OnProve(State, Verification, Purpose.Key, Result, Clock, Commands)
		end
		AfterVerification(State, Waiter, Clock, Commands)
		return true
	end
	if Purpose.Kind == "TouchWrite" then
		Tx.Purposes[RequestId] = nil
		local Finished = Touch.HearEnds(State, Purpose.Key, Purpose.Carried, Result, Commands)
		OnCarried(State, Finished, Clock, Commands)
		return true
	end
	if Purpose.Kind == "ResettleWrite" then
		Tx.Purposes[RequestId] = nil
		local Finished = Operators.OnResettleWrite(State, Purpose, Result, Clock, Commands)
		OnCarried(State, Finished, Clock, Commands)
		return true
	end
	if Purpose.Kind == "UncleanFence" then
		Tx.Purposes[RequestId] = nil
		local Next = Unclean.OnUncleanFence(State, Purpose, Result, Clock, Commands)
		InFlight.ActOnNext(State, Next, Clock, Commands)
		return true
	end
	if Purpose.Kind == "UncleanResolve" then
		Tx.Purposes[RequestId] = nil
		ReleaseRides(State, Purpose.Key, Purpose.Carried, Result, Clock, Commands)
		local Next = Unclean.OnUncleanResolve(State, Purpose, Result, Clock, Commands)
		InFlight.ActOnNext(State, Next, Clock, Commands)
		return true
	end
	return false
end

local function BoundOf(Server: ServerState, Key: StoreKey, Started: number): number
	return Started + Cache.StoreOf(Server, Key).Setup.Limits.OpBound
end

local function OnClock(State: State, Clock: number, Commands: { Command })
	local Tx = State.Tx
	local function IsHelpDue(_: number, Helping: TxState.Help): boolean
		return Help.IsWaitDue(Helping, Clock)
	end
	local function IsPendingDue(_: number, Pending: TxState.PendingCall): boolean
		return Clock >= BoundOf(State.Server, Pending.Legs[Pending.DeciderIndex].Key, Pending.Started)
	end
	local function IsCallDue(_: number, Waiting: Call): boolean
		if NextSteps.HasTimerReached(Waiting, Clock) then
			return true
		end
		return not Waiting.HasAnswered and Clock >= BoundOf(State.Server, Waiting.Decider, Waiting.Started)
	end
	local function IsResettleDue(_: number, Resettling: TxState.Resettle | TxState.PendingRead): boolean
		return Clock >= BoundOf(State.Server, Resettling.Key, Resettling.Started)
	end
	for _, Id in Sorted.SortedDueIds(Tx.Helps, IsHelpDue) do
		Help.HelpWaitDue(State, Tx.Helps[Id], Clock, Commands)
	end
	for _, Id in Sorted.SortedDueIds(Tx.PendingCalls, IsPendingDue) do
		TxCalls.FailPending(State, Tx.PendingCalls[Id], Reasons.Unresolved, Commands)
	end
	for _, Id in Sorted.SortedDueIds(Tx.Calls, IsCallDue) do
		local Waiting = Tx.Calls[Id]
		if not Waiting.HasAnswered and Clock >= BoundOf(State.Server, Waiting.Decider, Waiting.Started) then
			Reports.TimeOut(Waiting, Commands)
		end
		NextSteps.GateWaitDue(State, Waiting, Clock, Commands)
		NextSteps.ResendDue(State, Waiting, Clock, Commands)
		AfterAnswer.SendRidesDue(State, Waiting, Clock, Commands)
	end
	for _, Id in Sorted.SortedDueIds(Tx.Resettles, IsResettleDue) do
		Operators.TimeOut(State, Tx.Resettles[Id], Commands)
	end
	for _, Id in Sorted.SortedDueIds(Tx.PendingReads, IsResettleDue) do
		Operators.TimeOutPending(State, Tx.PendingReads[Id], Commands)
	end
end

local function NextWake(State: State, Clock: number): number?
	local Server = State.Server
	local Soonest: number? = nil
	for _, Helping in State.Tx.Helps do
		for _, DueAt in Helping.Waiting do
			Soonest = Composed.EarliestAfter(Soonest, DueAt, Clock)
		end
	end
	for _, Pending in State.Tx.PendingCalls do
		local Bound = BoundOf(Server, Pending.Legs[Pending.DeciderIndex].Key, Pending.Started)
		Soonest = Composed.EarliestAfter(Soonest, Bound, Clock)
	end
	for _, Waiting in State.Tx.Calls do
		if not Waiting.HasAnswered then
			Soonest = Composed.EarliestAfter(Soonest, BoundOf(Server, Waiting.Decider, Waiting.Started), Clock)
		end
		if Waiting.Phase == "GateWait" then
			Soonest = Composed.EarliestAfter(Soonest, Waiting.WaitUntil, Clock)
		end
		Soonest = Composed.EarliestAfter(Soonest, Waiting.ResendAt, Clock)
		if Waiting.Phase == "Resolving" and Waiting.Resolving ~= nil then
			Soonest = Composed.EarliestAfter(Soonest, Waiting.Resolving.RidesDueAt, Clock)
		end
	end
	for _, Resettling in State.Tx.Resettles do
		Soonest = Composed.EarliestAfter(Soonest, BoundOf(Server, Resettling.Key, Resettling.Started), Clock)
	end
	for _, Listing in State.Tx.PendingReads do
		Soonest = Composed.EarliestAfter(Soonest, BoundOf(Server, Listing.Key, Listing.Started), Clock)
	end
	return Composed.EarliestAfter(Soonest, Touch.NextWake(State, Clock), Clock)
end

local function QueueDeadline(Server: ServerState, Event: TxCallEvent, Arrived: number): number?
	local Deadline: number? = nil
	for _, Leg in Event.Legs do
		local LegDeadline = Shedding.QueueDeadline(Arrived, Cache.StoreOf(Server, Leg.Key).Setup.Limits)
		if Deadline == nil or LegDeadline < Deadline then
			Deadline = LegDeadline
		end
	end
	return Deadline
end

local function CloseAll(State: State, Commands: { Command })
	local Tx = State.Tx
	for _, Id in Sorted.SortedIds(Tx.PendingCalls) do
		TxCalls.FailPending(State, Tx.PendingCalls[Id], Reasons.Closed, Commands)
	end
	for _, Id in Sorted.SortedIds(Tx.Calls) do
		local Reading = Tx.Calls[Id]
		if Reading.Phase == "RetryRead" then
			TxCalls.Answer(Reading, ClosedAnswer, Commands)
			TxCalls.End(State, Reading, Commands)
		end
	end
end

local function AnswerAtEndedClose(State: State, Commands: { Command })
	local Shutdown = State.Sessions.Shutdown
	if Shutdown == nil or Shutdown.Kind ~= "Ended" then
		return
	end
	local Tx = State.Tx
	for _, Id in Sorted.SortedIds(Tx.Calls) do
		local Open = Tx.Calls[Id]
		if not Open.HasAnswered then
			Reports.TimeOut(Open, Commands)
		end
		TxCalls.StopOutcome(Open, Commands)
	end
	for _, Id in Sorted.SortedIds(Tx.Resettles) do
		Operators.TimeOut(State, Tx.Resettles[Id], Commands)
	end
	for _, Id in Sorted.SortedIds(Tx.PendingReads) do
		Operators.TimeOutPending(State, Tx.PendingReads[Id], Commands)
	end
end

local function AfterEvent(State: State, Clock: number, Commands: { Command })
	Touch.AfterEvent(State, Clock, Commands)
	AnswerAtEndedClose(State, Commands)
end

return {
	OnCall = OnCall,
	OnRead = OnRead,
	OnResult = OnResult,
	OnCarried = OnCarried,
	ReleaseRides = ReleaseRides,
	OnClock = OnClock,
	NextWake = NextWake,
	QueueDeadline = QueueDeadline,
	CloseAll = CloseAll,
	AnswerAtEndedClose = AnswerAtEndedClose,
	AfterEvent = AfterEvent,
}
