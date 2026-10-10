--!strict
--!optimize 2

--[=[
	Step: the server's state machine, step(state, event) -> (state', commands) (Charter item 23); the State is
	Composed's, changed in place.

	A call is held for the server's number; a replay that raises leaves the rest held. Each event sheds what passed
	its queue deadline (an Id's by the server's first Limits recorded) before any send. Only a probe calls FullWake.

	Return type: A plain table with Step and FullWake, and the State type.
	Example usage:
		local State = Composed.NewState(Server)
		Composed.OpenStore(State, Setup)
		local Next, Commands = Step.Step(State, { Clock = Now, Happening = { Kind = "Clock" } })
--]=]

local Adoption = require("./Sessions/Adoption")
local Cache = require("./Reading/Cache")
local Calls = require("./Calls")
local Closing = require("./Sessions/Closing")
local Composed = require("./Composed")
local CopiesServer = require("./Extras/Copies/Server")
local CutServer = require("./Cuts/Server")
local Events = require("./Events")
local ExtrasServer = require("./Extras/Server")
local Hearing = require("./Writing/Hearing")
local HotServer = require("./Hot/Server")
local InFlight = require("./Reading/InFlight")
local Numbers = require("./Writing/Numbers")
local Reasons = require("./Constants/Reasons")
local Replies = require("./Replies")
local Sending = require("./Writing/Sending")
local Shapes = require("./Shapes")
local Shedding = require("./Writing/Shedding")
local StepAnswer = require("./Tx/Call/StepAnswer")
local Touch = require("./Tx/Work/Touch")
local TxServer = require("./Tx/Server")
local Waking = require("./Sessions/Waking")
local Writers = require("./Writing/Writer")
local Writing = require("./Writing/Writing")

type Call = Events.Call
type Command = Events.Command
type Event = Events.Event
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type Limits = Shapes.Limits
type NumberAsk = Shapes.NumberAsk
type ServerState = Shapes.ServerState
type Held = Composed.Held

export type State = Composed.State

local LifeAsk: NumberAsk = table.freeze({ Kind = "Life" :: "Life" })
local SharedAsk: NumberAsk = table.freeze({ Kind = "Shared" :: "Shared" })

local RoutingFault = "Step: this call is never made."
local NoStores = `{RoutingFault} A counter answered on a server that holds no store.`
local UnusableCounterWarning = "the counter key holds a value its own writer never writes, or a count too large for"
	.. " another server number, so it gave no number. The server asks it again after the retry gap, and writes no key"
	.. " until a number lands."

local function IsAsked(State: State, Kind: "Life" | "Shared"): boolean
	for _, Ask in State.Server.NumbersAsked do
		if Ask.Kind == Kind then
			return true
		end
	end
	for _, Ask in State.NumberRetry.Asks do
		if Ask.Kind == Kind then
			return true
		end
	end
	return false
end

local function HoldsForWriter(State: State): boolean
	for _, Holding in State.Held do
		if Holding.Kind ~= "Held" or Holding.Call.Method ~= "Id" then
			return true
		end
	end
	return false
end

local function AskNumber(Server: ServerState, Ask: NumberAsk, Limits: Limits, Commands: { Command })
	local RequestId = Numbers.NewRequestId(Server)
	table.insert(Commands, Numbers.AskServerNumber(Server, RequestId, Ask, Limits))
end

local function AskNumbers(State: State, Clock: number, Commands: { Command })
	local Server = State.Server
	local Limits = State.Server.Limits
	if Limits == nil then
		return
	end
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	if Server.ServerNumber == nil then
		if not IsAsked(State, "Life") then
			AskNumber(Server, LifeAsk, Limits, Commands)
		end
		return
	end
	if Server.WriterNumber ~= nil or IsAsked(State, "Shared") then
		return
	end
	if HoldsForWriter(State) then
		AskNumber(Server, SharedAsk, Limits, Commands)
	end
end

local function AskAgain(State: State, Clock: number, Commands: { Command })
	local Retry = State.NumberRetry
	local Limits = State.Server.Limits
	if Limits == nil or Retry.RetryAt == nil or Clock < Retry.RetryAt then
		return
	end
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Asks = Retry.Asks
	Retry.Asks = {}
	Retry.RetryAt = nil
	for _, Ask in Asks do
		AskNumber(State.Server, Ask, Limits, Commands)
	end
end

local function ReplayHeld(State: State, Clock: number, Commands: { Command })
	for _ = 1, #State.Held do
		local Holding = State.Held[1]
		table.remove(State.Held, 1)
		if Holding.Kind == "Held" then
			Calls.OnCall(State, Holding.Call, Holding.At, Clock, Commands)
		else
			InFlight.OpenSession(State, Holding, Clock, Commands)
		end
	end
end

local function OnCounted(State: State, RequestId: number, Written: string?, Clock: number, Commands: { Command })
	local Server = State.Server
	local Limits = State.Server.Limits
	if Limits == nil then
		error(NoStores)
	end
	local Ask, Number = Numbers.TakeServerNumber(Server, RequestId, Written, Limits)
	local Retry = State.NumberRetry
	if Number == nil then
		Retry.ErrorsInARow += 1
		Retry.RetryAt = Clock + Sending.RetryGap(Retry.ErrorsInARow, Limits)
		table.insert(Retry.Asks, Ask)
		return
	end
	Retry.ErrorsInARow = 0
	Retry.IsUnusableWarned = false
	if Ask.Kind ~= "Writer" then
		Calls.TouchWriters(State)
		return ReplayHeld(State, Clock, Commands)
	end
	Writers.TakeWriterNumber(Server, Ask.Key, Number)
	Composed.NoteSendable(State, Ask.Key)
end

local function OnCounterUnusable(State: State, RequestId: number, Clock: number, Commands: { Command })
	local Limits = State.Server.Limits
	if Limits == nil then
		error(NoStores)
	end
	local Retry = State.NumberRetry
	if not Retry.IsUnusableWarned then
		Retry.IsUnusableWarned = true
		local CounterKey = Numbers.CounterKeyOf(State.Server, Limits)
		local Warn: Command = { Kind = "Warn", Key = CounterKey, Text = UnusableCounterWarning }
		table.insert(Commands, Warn)
	end
	OnCounted(State, RequestId, nil, Clock, Commands)
end

local function EndCloseAfterWork(State: State, Clock: number, Commands: { Command })
	Closing.EndClose(State.Server, State.Sessions, Composed.OpenCount(State), Clock, Commands)
end

local function OnRead(
	State: State,
	RequestId: number,
	Fetched: ReadOutcome,
	Fraction: number,
	Clock: number,
	Commands: { Command }
)
	if CutServer.OnRead(State, RequestId, Fetched, Clock, Commands) then
		return EndCloseAfterWork(State, Clock, Commands)
	end
	if TxServer.OnRead(State, RequestId, Fetched, Clock, Commands) then
		return EndCloseAfterWork(State, Clock, Commands)
	end
	if ExtrasServer.OnRead(State, RequestId, Fetched, Fraction, Clock, Commands) then
		return EndCloseAfterWork(State, Clock, Commands)
	end
	if HotServer.OnRead(State, RequestId, Fetched, Clock) then
		return EndCloseAfterWork(State, Clock, Commands)
	end
	local Out = State.Reads[RequestId]
	if Out ~= nil then
		return InFlight.OnReadResult(State, Out, Fetched, Clock, Commands)
	end
	local Open = InFlight.TakeIdleReader(State.Sessions, RequestId)
	if Open == nil then
		return Writing.LearnIncarnation(State, RequestId, Fetched, Clock, Commands)
	end
	Composed.NoteTimersMovedAt(State, Open.Text, Open.Key)
	if Adoption.OnIdleRead(State.Server, State.Sessions, Open.Key, RequestId, Fetched, Clock, Commands) then
		Touch.ActForSession(State, Open.Key, Clock, Commands)
	end
end

local function OnResult(State: State, RequestId: number, Result: Outcome, Clock: number, Commands: { Command })
	if CutServer.OnResult(State, RequestId, Result, Clock, Commands) then
		return EndCloseAfterWork(State, Clock, Commands)
	end
	if TxServer.OnResult(State, RequestId, Result, Clock, Commands) then
		return EndCloseAfterWork(State, Clock, Commands)
	end
	if HotServer.OnResult(State, RequestId, Result, Clock, Commands) then
		return EndCloseAfterWork(State, Clock, Commands)
	end
	local Out = State.Reads[RequestId]
	if Out == nil then
		local Finished = Hearing.Hear(State, RequestId, Result, Clock, Commands)
		TxServer.OnCarried(State, Finished, Clock, Commands)
		return
	end
	InFlight.OnUpdateResult(State, Out, Result, Clock, Commands)
end

local function IdDeadline(Server: ServerState, Arrived: number): number?
	local Recorded = Server.Limits
	if Recorded == nil then
		return nil
	end
	return Shedding.QueueDeadline(Arrived, Recorded)
end

local function DeadlineOf(Server: ServerState, Holding: Held): number?
	if Holding.Kind ~= "Held" then
		return InFlight.BoundOf(Server, Holding.Out)
	end
	local Call = Holding.Call
	if Call.Method == "Id" then
		return IdDeadline(Server, Holding.At)
	end
	if Call.Method == "Tx" then
		return TxServer.QueueDeadline(Server, Call, Holding.At)
	end
	if Call.Method == "Bump" then
		return Shedding.StoreQueueDeadline(Server, Call.Store, Holding.At)
	end
	local Hot = HotServer.HotCallOf(Call)
	if Hot ~= nil then
		return Shedding.StoreQueueDeadline(Server, Hot.Store, Holding.At)
	end
	if
		Call.Method ~= "Apply"
		and Call.Method ~= "Edit"
		and Call.Method ~= "Commit"
		and Call.Method ~= "Resettle"
		and Call.Method ~= "Erase"
		and Call.Method ~= "Reset"
	then
		return nil
	end
	return Shedding.QueueDeadline(Holding.At, Cache.StoreOf(Server, Call.Key).Setup.Limits)
end

local function TimeOutHeld(State: State, Clock: number, Commands: { Command })
	if #State.Held == 0 then
		return
	end
	local Kept: { Held } = {}
	for _, Holding in State.Held do
		local Deadline = DeadlineOf(State.Server, Holding)
		if Deadline == nil or Clock < Deadline then
			table.insert(Kept, Holding)
		else
			Replies.ReplyFailed(Commands, Calls.CallIdOf(Holding), Reasons.Busy)
		end
	end
	State.Held = Kept
end

local function ShedPastDeadline(State: State, Clock: number, Commands: { Command })
	TimeOutHeld(State, Clock, Commands)
	Waking.ShedPastDeadline(State, Clock, Commands)
end

local function OnClock(State: State, Clock: number, Commands: { Command })
	InFlight.TickReads(State, Clock, Commands)
	AskAgain(State, Clock, Commands)
	TxServer.OnClock(State, Clock, Commands)
	CutServer.OnClock(State, Clock, Commands)
	ExtrasServer.OnClock(State, Clock, Commands)
	HotServer.OnClock(State, Clock, Commands)
	Waking.OnClock(State, Clock, Commands)
end

local function OthersWake(State: State, Soonest: number?, Clock: number): number?
	local Server = State.Server
	for _, Holding in State.Held do
		Soonest = Composed.EarliestAfter(Soonest, DeadlineOf(Server, Holding), Clock)
	end
	for _, Out in State.Reads do
		Soonest = Composed.EarliestAfter(Soonest, Out.RetryAt, Clock)
		Soonest = Composed.EarliestAfter(Soonest, InFlight.BoundOf(Server, Out), Clock)
	end
	Soonest = Composed.EarliestAfter(Soonest, TxServer.NextWake(State, Clock), Clock)
	Soonest = Composed.EarliestAfter(Soonest, CutServer.NextWake(State, Clock), Clock)
	Soonest = Composed.EarliestAfter(Soonest, ExtrasServer.NextWake(State, Clock), Clock)
	Soonest = Composed.EarliestAfter(Soonest, HotServer.NextWake(State, Clock), Clock)
	return Composed.EarliestAfter(Soonest, State.NumberRetry.RetryAt, Clock)
end

local function NextWake(State: State, Event: Event): number?
	if Event.Happening.Kind == "Clock" then
		return OthersWake(State, Waking.NextWake(State, Event.Clock), Event.Clock)
	end
	return OthersWake(State, Waking.FoldWake(State, Event.Clock), Event.Clock)
end

local function FullWake(State: State, Clock: number): number?
	return OthersWake(State, Waking.TrueWake(State, Clock), Clock)
end

local function Handle(State: State, Event: Event, Commands: { Command })
	local Happening = Event.Happening
	local Clock = Event.Clock
	if Happening.Kind == "Call" then
		return Calls.OnCall(State, Happening, Clock, Clock, Commands)
	end
	if Happening.Kind == "Result" then
		return OnResult(State, Happening.RequestId, Happening.Outcome, Clock, Commands)
	end
	if Happening.Kind == "Read" then
		CopiesServer.NoteRead(State, Happening.RequestId, Happening.Fetched, Happening.Fraction)
		return OnRead(State, Happening.RequestId, Happening.Fetched, Happening.Fraction, Clock, Commands)
	end
	if Happening.Kind == "MemoryRead" then
		ExtrasServer.OnMemoryRead(State, Happening.RequestId, Happening.Fetched, Happening.Fraction, Clock, Commands)
		return EndCloseAfterWork(State, Clock, Commands)
	end
	if Happening.Kind == "MemoryResult" then
		ExtrasServer.OnMemoryResult(State, Happening.RequestId, Happening.Outcome, Clock, Commands)
		return EndCloseAfterWork(State, Clock, Commands)
	end
	if Happening.Kind == "Decoded" then
		CopiesServer.OnDecoded(State, Happening.RequestId, Happening.Outcome, Clock, Commands)
		return EndCloseAfterWork(State, Clock, Commands)
	end
	if Happening.Kind == "Counted" then
		return OnCounted(State, Happening.RequestId, Happening.Written, Clock, Commands)
	end
	if Happening.Kind == "CounterUnusable" then
		return OnCounterUnusable(State, Happening.RequestId, Clock, Commands)
	end
	if Happening.Kind == "Send" then
		return Writing.SendOnEvent(State, Happening.Key, Clock, Commands)
	end
	if Happening.Kind == "Clock" then
		return OnClock(State, Clock, Commands)
	end
	local Erased = CutServer.OnRemoved(State, Happening.RequestId, Happening.IsOk, Clock)
	if Erased ~= nil then
		CopiesServer.AdviseErased(State, Erased, Commands)
	end
	if HotServer.OnRemoved(State, Happening.RequestId, Happening.IsOk, Commands) then
		EndCloseAfterWork(State, Clock, Commands)
	end
end

local function AnswerAtEndedClose(State: State, Clock: number, Commands: { Command })
	Calls.AnswerAtEndedClose(State, Commands)
	TxServer.AnswerAtEndedClose(State, Commands)
	CutServer.AnswerAtEndedClose(State, Commands)
	ExtrasServer.AnswerAtEndedClose(State, Clock, Commands)
end

local function Step(State: State, Event: Event): (State, { Command })
	local Commands: { Command } = {}
	ShedPastDeadline(State, Event.Clock, Commands)
	Handle(State, Event, Commands)
	TxServer.AfterEvent(State, Event.Clock, Commands)
	CutServer.AfterEvent(State, Event.Clock, Commands)
	ExtrasServer.AfterEvent(State, Event.Clock, Commands)
	HotServer.AfterEvent(State, Event.Clock, Commands)
	CopiesServer.OnCopyReads(State, Event.Clock, Commands)
	if #State.Server.StepOut == 0 then
		EndCloseAfterWork(State, Event.Clock, Commands)
	end
	if Closing.IsEnded(State.Sessions) then
		AnswerAtEndedClose(State, Event.Clock, Commands)
		HotServer.AnswerAtEndedClose(State, Event.Clock, Commands)
		HotServer.AfterEndedClose(State, Event.Clock, Commands)
		StepAnswer.AbandonAtClose(State)
		CutServer.AbandonAtClose(State)
	end
	State.Server.Landed = {}
	Writing.ReadySendable(State, Event.Clock, Commands)
	AskNumbers(State, Event.Clock, Commands)
	local At = NextWake(State, Event)
	if At ~= nil then
		local Wake: Command = { Kind = "Wake", At = At }
		table.insert(Commands, Wake)
	end
	return State, Commands
end

return {
	Step = Step,
	FullWake = FullWake,
}
