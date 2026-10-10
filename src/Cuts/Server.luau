--!strict
--!optimize 2

--[=[
	Server: routes a cut call's events to their owners. A request id in State.Cuts.Purposes is the cuts', forgotten
	once heard. A call past its bound answers Unresolved and works on while it progresses. At CloseAll a call that
	sent no cut request answers Closed; the others answer Unresolved once the close has ended, and AbandonAtClose
	drops every call and helper.

	Return type: A plain table with OnCall, OnRead, OnResult, OnRemoved, OnClock, NextWake, CloseAll,
	AnswerAtEndedClose, AbandonAtClose and AfterEvent.
	Example usage:
		if not Server.OnResult(State, RequestId, Result, Clock, Commands) then ... end
--]=]

local Cache = require("../Reading/Cache")
local Call = require("./Call/Call")
local Composed = require("../Composed")
local CutShapes = require("./Shapes")
local CutState = require("./State")
local Drain = require("./Call/Drain")
local Events = require("../Events")
local Helper = require("./Call/Helper")
local Names = require("../Encoding/Names")
local NextSteps = require("../Tx/Call/NextSteps")
local Reasons = require("../Constants/Reasons")
local Removal = require("./Seals/Removal")
local Reports = require("./Call/Reports")
local Sorted = require("../Sorted")
local Stamps = require("./Seals/Stamps")
local Touch = require("../Tx/Work/Touch")
local TxServer = require("../Tx/Server")

type Command = Events.Command
type StoreKey = Names.StoreKey
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type EraseOrResetCall = CutShapes.EraseCall | CutShapes.ResetCall
type CutCall = CutState.CutCall
type State = Composed.State

local function OnCall(State: State, Event: EraseOrResetCall, Arrived: number, Clock: number, Commands: { Command })
	Call.Begin(State, Event, Arrived, Clock, Commands)
end

local function AfterHelper(State: State, Ended: CutCall, Clock: number, Commands: { Command })
	for _, Waiter in Helper.TakeWaiters(State.Cuts, Ended.Key) do
		if Waiter.Kind == "Touch" then
			Touch.AfterWork(State, Waiter.Key, Clock, Commands)
		else
			local Waiting = State.Tx.Calls[Waiter.CallId]
			if Waiting ~= nil then
				NextSteps.AfterGate(State, Waiting, Clock, Commands)
			end
		end
	end
end

local function ResumeIfHelperEnded(State: State, Working: CutCall, Clock: number, Commands: { Command })
	if Working.Role == "Helper" and Working.Phase == "Done" then
		AfterHelper(State, Working, Clock, Commands)
	end
end

local function OnRead(
	State: State,
	RequestId: number,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
): boolean
	local Cuts = State.Cuts
	local Purpose = Cuts.Purposes[RequestId]
	if Purpose == nil then
		return false
	end
	if Purpose.Kind == "IncarnationRead" then
		Cuts.Purposes[RequestId] = nil
		local Reading = CutState.FindCall(Cuts, Purpose.CallId)
		if Reading ~= nil then
			Call.OnIncarnationRead(State, Reading, Fetched, Clock, Commands)
			ResumeIfHelperEnded(State, Reading, Clock, Commands)
		end
		return true
	end
	if Purpose.Kind == "OrphanRead" then
		Cuts.Purposes[RequestId] = nil
		local Draining = CutState.FindCall(Cuts, Purpose.CallId)
		if Draining ~= nil then
			Drain.OnOrphanRead(State, Draining, Purpose.Mark, Fetched, Clock, Commands)
		end
		return true
	end
	if Purpose.Kind == "SealCheck" then
		Cuts.Purposes[RequestId] = nil
		Stamps.OnCheckRead(State, Purpose, Fetched, Clock, Commands)
		return true
	end
	return false
end

local function OnResult(State: State, RequestId: number, Result: Outcome, Clock: number, Commands: { Command }): boolean
	local Cuts = State.Cuts
	local Purpose = Cuts.Purposes[RequestId]
	if Purpose == nil then
		return false
	end
	if Purpose.Kind == "Cut" then
		Cuts.Purposes[RequestId] = nil
		TxServer.ReleaseRides(State, Purpose.Key, Purpose.Carried, Result, Clock, Commands)
		local Cutting = CutState.FindCall(Cuts, Purpose.CallId)
		if Cutting ~= nil then
			Reports.HearCut(State, Cutting, Result, Clock, Commands)
			ResumeIfHelperEnded(State, Cutting, Clock, Commands)
		end
		return true
	end
	if Purpose.Kind == "Fence" then
		Cuts.Purposes[RequestId] = nil
		local Fencing = CutState.FindCall(Cuts, Purpose.CallId)
		if Fencing ~= nil then
			Drain.OnFence(State, Fencing, Purpose.Decider, Result, Clock, Commands)
		end
		return true
	end
	if Purpose.Kind == "SealStamp" then
		Cuts.Purposes[RequestId] = nil
		Stamps.OnStampResult(State, Purpose.Key, Result, Clock, Commands)
		local StampWaiter = if Purpose.CallId ~= nil then Cuts.Calls[Purpose.CallId] else nil
		if StampWaiter ~= nil then
			Reports.AfterStamp(State, StampWaiter, Commands)
		end
		return true
	end
	return false
end

local function OnRemoved(State: State, RequestId: number, IsOk: boolean, Clock: number): StoreKey?
	return Removal.OnRemoved(State, RequestId, IsOk, Clock)
end

local function CutBoundOf(State: State, Cutting: CutCall): number
	local Limits = Cache.StoreOf(State.Server, Cutting.Key).Setup.Limits
	if Cutting.CutKind == "Erase" then
		return Cutting.Started + Limits.EraseBound
	end
	return Cutting.Started + Limits.ResetBound
end

local function IsResendDue(Cutting: CutCall, Clock: number): boolean
	local RetryAt = Cutting.RetryAt
	if RetryAt ~= nil and Clock >= RetryAt then
		return true
	end
	local WaitUntil = Cutting.WaitUntil
	return WaitUntil ~= nil and Clock >= WaitUntil
end

local function ActOnDue(State: State, Cutting: CutCall, Clock: number, Commands: { Command })
	if Cutting.Phase == "Draining" then
		Drain.OrphanReadsDue(State, Cutting, Clock, Commands)
		Drain.WaitDue(State, Cutting, Clock, Commands)
		return
	end
	if Cutting.Phase == "Waiting" and IsResendDue(Cutting, Clock) then
		Call.SendCut(State, Cutting, Clock, Commands)
	end
end

local function IsWorkDue(State: State, Cutting: CutCall, Clock: number): boolean
	if Cutting.Phase == "Waiting" then
		return IsResendDue(Cutting, Clock)
	end
	return Drain.IsDue(State, Cutting, Clock)
end

local function OnClock(State: State, Clock: number, Commands: { Command })
	local Cuts = State.Cuts
	local function IsCallDue(_: number, Working: CutCall): boolean
		if not Working.HasAnswered and Clock >= CutBoundOf(State, Working) then
			return true
		end
		return IsWorkDue(State, Working, Clock)
	end
	local function IsHelperDue(Helping: CutCall): boolean
		return IsWorkDue(State, Helping, Clock)
	end
	for _, Id in Sorted.SortedDueIds(Cuts.Calls, IsCallDue) do
		local Working = Cuts.Calls[Id]
		if not Working.HasAnswered and Clock >= CutBoundOf(State, Working) then
			Reports.TimeOut(Working, Commands)
		end
		ActOnDue(State, Working, Clock, Commands)
	end
	for _, Text in Sorted.SortedDueTexts(Cuts.Helpers, IsHelperDue) do
		ActOnDue(State, Cuts.Helpers[Text], Clock, Commands)
	end
	Stamps.OnClock(State, Clock, Commands)
end

local function WakeOfWork(State: State, Working: CutCall, Soonest: number?, Clock: number): number?
	if Working.Phase == "Waiting" then
		Soonest = Composed.EarliestAfter(Soonest, Working.RetryAt, Clock)
		Soonest = Composed.EarliestAfter(Soonest, Working.WaitUntil, Clock)
	end
	return Composed.EarliestAfter(Soonest, Drain.NextWake(State, Working, Clock), Clock)
end

local function NextWake(State: State, Clock: number): number?
	local Soonest: number? = nil
	for _, Working in State.Cuts.Calls do
		if not Working.HasAnswered then
			Soonest = Composed.EarliestAfter(Soonest, CutBoundOf(State, Working), Clock)
		end
		Soonest = WakeOfWork(State, Working, Soonest, Clock)
	end
	for _, Helping in State.Cuts.Helpers do
		Soonest = WakeOfWork(State, Helping, Soonest, Clock)
	end
	return Composed.EarliestAfter(Soonest, Stamps.NextWake(State, Clock), Clock)
end

local function CloseAll(State: State, Commands: { Command })
	local Cuts = State.Cuts
	for _, Id in Sorted.SortedIds(Cuts.Calls) do
		local Reading = Cuts.Calls[Id]
		if Reading.Phase == "Identity" then
			Call.AnswerNo(Reading, Reasons.Closed, Commands)
			CutState.EndCall(Cuts, Reading)
		end
	end
end

local function AnswerAtEndedClose(State: State, Commands: { Command })
	local Shutdown = State.Sessions.Shutdown
	if Shutdown == nil or Shutdown.Kind ~= "Ended" then
		return
	end
	for _, Id in Sorted.SortedIds(State.Cuts.Calls) do
		Reports.TimeOut(State.Cuts.Calls[Id], Commands)
	end
end

local function AbandonAtClose(State: State)
	local Cuts = State.Cuts
	Cuts.Calls = {}
	Cuts.Helpers = {}
	Cuts.Waiters = {}
end

local function AfterEvent(State: State, Clock: number, Commands: { Command })
	Stamps.AfterEvent(State, Clock, Commands)
	AnswerAtEndedClose(State, Commands)
end

return {
	OnCall = OnCall,
	OnRead = OnRead,
	OnResult = OnResult,
	OnRemoved = OnRemoved,
	OnClock = OnClock,
	NextWake = NextWake,
	CloseAll = CloseAll,
	AnswerAtEndedClose = AnswerAtEndedClose,
	AbandonAtClose = AbandonAtClose,
	AfterEvent = AfterEvent,
}
