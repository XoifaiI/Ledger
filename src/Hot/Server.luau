--!strict
--!optimize 2

--[=[
	Server: routes quantity calls to their walks, opens, closes and moves (sheet H6 to H8). OnClock resends a fence or
	an open and ends what is unheard by B_op. AfterEvent files landed parts, drains the outbox, hands a step Tx's answer
	to its call and resumes a walk whose Tx closed. A late fence result goes to Outcomes. At an ended close the outbox
	drains before any open call answers Unresolved.

	Return type: A plain table with HotCallOf, OnCall, MustWait, OnRead, OnResult, OnRemoved, OnClock, NextWake,
	AfterEvent, AnswerAtEndedClose and AfterEndedClose.
	Example usage:
		if not Server.MustWait(State, Call, Clock) then Server.OnCall(State, Call, Arrived, Clock, Commands) end
--]=]

local Cache = require("../Reading/Cache")
local CloseCalls = require("./Calls/Close")
local Closing = require("../Sessions/Closing")
local Composed = require("../Composed")
local Delivery = require("./Delivery")
local Events = require("../Events")
local Fence = require("./Walk/Fence")
local Gather = require("./Calls/Gather")
local HotShapes = require("./Shapes")
local HotState = require("./State")
local Moves = require("./Calls/Moves")
local Numbers = require("../Writing/Numbers")
local OpenCalls = require("./Calls/Open")
local PartBuild = require("./Part/Build")
local PartRead = require("./Walk/Read")
local Record = require("../Constants/Record")
local Reports = require("./Walk/Reports")
local Sorted = require("../Sorted")
local Tidy = require("../Extras/Tidy")
local View = require("./Walk/View")
local Walk = require("./Walk/Walk")
local WalkOutcomes = require("./Walk/Outcomes")

type Command = Events.Command
type GatherCall = HotShapes.GatherCall
type HoldCall = HotShapes.HoldCall
type HotCall = HotShapes.HotCall
type TakeCall = HotShapes.TakeCall
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type HotWalk = HotState.Walk
type Purpose = HotState.Purpose
type ResultHandler = (State, Purpose, Outcome, number, { Command }) -> ()
type CallHandler = (State, HotCall, number, number, { Command }) -> ()
type CanStartHandler = (State, HotCall, number) -> boolean
type State = Composed.State

local KeyKinds = Record.KeyKind

local ModuleName = "Server"
local RoutingFault = `{ModuleName}: this call is never made.`
local MisroutedResult = `{RoutingFault} An open result is routed to the open handler only.`

local function OnTake(State: State, Call: TakeCall | GatherCall, Arrived: number, Clock: number, Commands: { Command })
	if Call.IsGather then
		return Gather.StartGather(State, Call, Arrived, Clock, Commands)
	end
	Walk.StartTake(State, Call, Arrived, Clock, Commands)
end

local function OnHold(State: State, Call: HoldCall, Arrived: number, Clock: number, Commands: { Command })
	Walk.StartHold(State, Call, Arrived, Clock, Commands)
end

local CallHandlers = {
	Take = OnTake,
	Hold = OnHold,
	Open = OpenCalls.StartOpen,
	Close = CloseCalls.StartClose,
	Confirm = Moves.StartConfirm,
	ReleaseHold = Moves.StartRelease,
	Deposit = Moves.StartDeposit,
	Withdraw = Moves.StartWithdraw,
}

type HandledMethod = keyof<typeof(CallHandlers)>

local function CanStartOpen(State: State): boolean
	return State.Server.ServerNumber ~= nil
end

local function CanStartTake(State: State, Call: TakeCall | GatherCall, Clock: number): boolean
	if Call.IsGather then
		return Gather.CanStart(State)
	end
	return Walk.CanStart(State, Call, Clock)
end

local CanStartHandlers = {
	Take = CanStartTake,
	Hold = Walk.CanStart,
	Open = CanStartOpen,
	Close = CloseCalls.CanStartClose,
	Confirm = Moves.CanStartConfirm,
	ReleaseHold = Moves.CanStartRelease,
	Deposit = Moves.CanStartDeposit,
	Withdraw = Moves.CanStartWithdraw,
}

local function HotCallOf(Call: Events.Call): HotCall?
	if (CallHandlers :: { [string]: unknown })[Call.Method] == nil then
		return nil
	end
	return Call :: HotCall
end

local function OnCall(State: State, Call: HotCall, Arrived: number, Clock: number, Commands: { Command })
	local Handler = (CallHandlers :: { [HandledMethod]: CallHandler })[Call.Method]
	Handler(State, Call, Arrived, Clock, Commands)
end

local function MustWait(State: State, Call: HotCall, Clock: number): boolean
	local CanStart = (CanStartHandlers :: { [HandledMethod]: CanStartHandler })[Call.Method]
	return not CanStart(State, Call, Clock)
end

local function OnRead(State: State, RequestId: number, Fetched: ReadOutcome, Clock: number): boolean
	local Purposes = State.Hot.Purposes
	local Purpose = Purposes[RequestId]
	if Purpose == nil or Purpose.Kind ~= "PartRead" then
		return false
	end
	Purposes[RequestId] = nil
	local Index = Purpose.Index
	local Known = HotState.ViewOf(State.Hot, Purpose.Store, Purpose.Scope, Purpose.Quantity)
	local Out = Known.ReadOut[Index]
	if Out ~= nil and Out.RequestId == RequestId then
		Known.ReadOut[Index] = nil
	end
	local Read = PartRead.LearnPart(State, Purpose.Store, Purpose.Scope, Purpose.Quantity, Index, Fetched, Clock)
	if Read == nil or Read.Kind ~= "Kept" then
		return true
	end
	local Server = State.Server
	local Key = PartBuild.PartKey(Purpose.Store, Purpose.Scope, Purpose.Quantity, Index)
	if not Tidy.IsDue(Read.Kept, Numbers.EntryFor(Server, Key), Clock) then
		return true
	end
	local Walking = State.Hot.Walks[Purpose.CallId]
	if Walking == nil then
		Tidy.Owe(State, Key, Clock, Purpose.Fraction)
	else
		table.insert(Walking.Tidies, Key)
	end
	return true
end

local function OnFenceResult(State: State, Purpose: Purpose, Result: Outcome, Clock: number, Commands: { Command })
	local Walking = State.Hot.Walks[Purpose.CallId]
	if Walking ~= nil and Walking.Fence ~= nil then
		return Reports.OnFenceResult(State, Walking, Result, Clock, Commands)
	end
	WalkOutcomes.OnLateFence(State, Purpose.CallId, Result, Commands)
end

local function OnOpenResult(State: State, Purpose: Purpose, Result: Outcome, Clock: number, Commands: { Command })
	if Purpose.Kind ~= "Open" then
		error(MisroutedResult)
	end
	OpenCalls.OnOpenResult(State, State.Hot.Opens[Purpose.CallId], Purpose.Index, Result, Clock, Commands)
end

local ResultHandlers = {
	Fence = OnFenceResult,
	Open = OnOpenResult,
}

local function OnResult(State: State, RequestId: number, Result: Outcome, Clock: number, Commands: { Command }): boolean
	local Purposes = State.Hot.Purposes
	local Purpose = Purposes[RequestId]
	if Purpose == nil then
		return false
	end
	local Handler = (ResultHandlers :: { [string]: ResultHandler? })[Purpose.Kind]
	if Handler == nil then
		return false
	end
	Purposes[RequestId] = nil
	Handler(State, Purpose, Result, Clock, Commands)
	return true
end

local function OnRemoved(State: State, RequestId: number, IsOk: boolean, Commands: { Command }): boolean
	local Purposes = State.Hot.Purposes
	local Purpose = Purposes[RequestId]
	if Purpose == nil or Purpose.Kind ~= "Remove" then
		return false
	end
	Purposes[RequestId] = nil
	CloseCalls.OnRemoved(State, Purpose.CallId, RequestId, IsOk, Commands)
	return true
end

local function FenceBoundOf(State: State, Walking: HotWalk): number?
	local Sent = Walking.Fence
	if Sent == nil then
		return nil
	end
	return Sent.SentAt + HotState.OpBoundOf(State.Server, Walking.Call.Store)
end

local function WaitBoundOf(State: State, Walking: HotWalk): number?
	local HeardAt = Walking.HeardAt
	if Walking.TxStepId == nil or HeardAt == nil then
		return nil
	end
	return HeardAt + HotState.OpBoundOf(State.Server, Walking.Call.Store)
end

local function OnClock(State: State, Clock: number, Commands: { Command })
	for _, CallId in Sorted.SortedIds(State.Hot.Walks) do
		local Walking = State.Hot.Walks[CallId]
		local WaitAt = WaitBoundOf(State, Walking)
		if WaitAt ~= nil and Clock >= WaitAt then
			Reports.EndUnresolved(State, Walking, Clock, Commands)
			continue
		end
		local BoundAt = FenceBoundOf(State, Walking)
		local Sent = Walking.Fence
		if BoundAt ~= nil and Clock >= BoundAt then
			Reports.EndAtFenceBound(State, Walking, Clock, Commands)
		elseif Sent ~= nil and Sent.RetryAt ~= nil and Clock >= Sent.RetryAt then
			Fence.ResendFence(State, Walking, Clock, Commands)
		end
	end
	OpenCalls.OnClock(State, Clock, Commands)
	CloseCalls.OnClock(State, Clock, Commands)
end

local function NextWake(State: State, Clock: number): number?
	local Soonest: number? = nil
	for _, Walking in State.Hot.Walks do
		Soonest = Composed.EarliestAfter(Soonest, FenceBoundOf(State, Walking), Clock)
		Soonest = Composed.EarliestAfter(Soonest, WaitBoundOf(State, Walking), Clock)
		if Walking.Fence ~= nil then
			Soonest = Composed.EarliestAfter(Soonest, Walking.Fence.RetryAt, Clock)
		end
	end
	Soonest = Composed.EarliestAfter(Soonest, OpenCalls.NextWake(State, Clock), Clock)
	return Composed.EarliestAfter(Soonest, CloseCalls.NextWake(State, Clock), Clock)
end

local function NoteLandedParts(State: State)
	for _, Landed in State.Server.Landed do
		if Cache.KindOfKey(Landed.Key) ~= KeyKinds.Part then
			continue
		end
		local Ref = PartBuild.PartOfKey(Landed.Key)
		local Known = HotState.ViewOf(State.Hot, Landed.Key.Store, Landed.Key.Scope, Ref)
		View.NoteLanded(Known, Ref.Index, Landed)
	end
end

local function AnswerOpenCalls(State: State, Clock: number, Commands: { Command })
	Delivery.DrainStepOut(State, Clock, Commands)
	for _, CallId in Sorted.SortedIds(State.Hot.Walks) do
		Reports.EndUnresolved(State, State.Hot.Walks[CallId], Clock, Commands)
	end
	WalkOutcomes.EndOwed(State, Commands)
	OpenCalls.EndUnresolved(State, Commands)
	CloseCalls.EndUnresolved(State, Commands)
end

local function AfterEvent(State: State, Clock: number, Commands: { Command })
	NoteLandedParts(State)
	local HasOwnerEntry = Delivery.DrainStepOut(State, Clock, Commands)
	local IsDelivered = Delivery.DeliverTxSteps(State, Clock, Commands)
	local IsResumed = Reports.ResumeWalks(State, Clock, Commands)
	if HasOwnerEntry or IsDelivered or IsResumed then
		Closing.EndClose(State.Server, State.Sessions, Composed.OpenCount(State), Clock, Commands)
		Delivery.DrainStepOut(State, Clock, Commands)
	end
	if Closing.IsEnded(State.Sessions) then
		AnswerOpenCalls(State, Clock, Commands)
	end
end

return {
	HotCallOf = HotCallOf,
	OnCall = OnCall,
	MustWait = MustWait,
	OnRead = OnRead,
	OnResult = OnResult,
	OnRemoved = OnRemoved,
	OnClock = OnClock,
	NextWake = NextWake,
	AfterEvent = AfterEvent,
	AnswerAtEndedClose = AnswerOpenCalls,
	AfterEndedClose = Delivery.AfterEndedClose,
}
