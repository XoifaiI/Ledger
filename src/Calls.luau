--!strict
--!optimize 2

--[=[
	Calls: what the server does with an arriving call, once Step has its State. First, in order: CloseAll, a call after
	the close began, a Behind session's call, a call that must wait for a number. An Id is closed to only once the close
	ended with no server number; AnswerAtEndedClose then answers the held Ids Closed.

	Return type: A plain table with OnCall, WouldWait, CallIdOf, TouchWriters and AnswerAtEndedClose.
	Example usage:
		Calls.OnCall(State, Call, Clock, Clock, Commands)
--]=]

local Closing = require("./Sessions/Closing")
local Composed = require("./Composed")
local CutServer = require("./Cuts/Server")
local CutShapes = require("./Cuts/Shapes")
local DidApply = require("./Reading/DidApply")
local Durable = require("./Writing/Durable")
local Events = require("./Events")
local ExtrasServer = require("./Extras/Server")
local ExtrasShapes = require("./Extras/Shapes")
local Hearing = require("./Writing/Hearing")
local HotServer = require("./Hot/Server")
local HotShapes = require("./Hot/Shapes")
local InFlight = require("./Reading/InFlight")
local Names = require("./Encoding/Names")
local Numbers = require("./Writing/Numbers")
local Reads = require("./Reading/Reads")
local Reasons = require("./Constants/Reasons")
local Replies = require("./Replies")
local Session = require("./Sessions/Session")
local Shapes = require("./Shapes")
local Showables = require("./Reading/Showables")
local Sorted = require("./Sorted")
local TxServer = require("./Tx/Server")

type Call = Events.Call
type Command = Events.Command
type DidApplyCall = DidApply.DidApplyCall
type AskedName = Shapes.AskedName
type DurableCall = Durable.DurableCall
type ApplyCall = Session.ApplyCall
type ReleaseCall = Session.ReleaseCall
type LoadCall = Reads.LoadCall
type ReadOut = Reads.ReadOut
type KeyCall = Reads.ReadCall
type IdCall = { read CallId: number }
type EditCall = DurableCall & { read MustExist: boolean }
type PeekCall = KeyCall & { read Method: Events.ReadMethod }
type TxCall = Events.TxCall
type PendingCall = Events.PendingCall
type ResettleCall = Events.ResettleCall
type EraseOrResetCall = CutShapes.EraseCall | CutShapes.ResetCall
type ExtrasCall = ExtrasShapes.ExtrasCall
type HotCall = HotShapes.HotCall
type ServerState = Shapes.ServerState
type HeldCall = Composed.HeldCall
type Held = Composed.Held
type CallHandler = (State, Call, number, number, { Command }) -> ()
type State = Composed.State

local function DrawName(Server: ServerState, CallId: number, Clock: number, Commands: { Command })
	local Fresh = Numbers.DrawFreshId(Server)
	local Drawn: AskedName = { Kind = "Drawn", Server = Fresh.Server, Counter = Fresh.Counter, Stamp = Clock }
	Replies.Reply(Commands, CallId, { Kind = "Succeeded", Value = Drawn })
end

local function CallIdOf(Holding: Held): number
	if Holding.Kind == "Held" then
		return Holding.Call.CallId
	end
	return Holding.Out.CallId
end

local function TouchWriters(State: State)
	for _, Store in State.Server.Stores do
		for Text, Writer in Store.Writers do
			Composed.NoteSendableAt(State, Text, Writer.Key)
		end
	end
end

local function NoteSessionsMoved(State: State)
	for Text, Open in State.Sessions.Open do
		Composed.NoteTimersMovedAt(State, Text, Open.Key)
	end
end

local function IsHeldId(Holding: Held): boolean
	return Holding.Kind == "Held" and Holding.Call.Method == "Id"
end

local function AnswerAtEndedClose(State: State, Commands: { Command })
	local Kept: { Held } = {}
	for _, Holding in State.Held do
		if IsHeldId(Holding) then
			Replies.ReplyFailed(Commands, CallIdOf(Holding), Reasons.Closed)
		else
			table.insert(Kept, Holding)
		end
	end
	State.Held = Kept
end

local function CloseLoads(State: State, Commands: { Command })
	local function IsLoad(_: number, Out: ReadOut): boolean
		return Out.Want.Kind == "Load"
	end
	for _, RequestId in Sorted.SortedDueIds(State.Reads, IsLoad) do
		Replies.ReplyFailed(Commands, State.Reads[RequestId].CallId, Reasons.Closed)
		State.Reads[RequestId] = nil
	end
	local Kept: { Held } = {}
	for _, Holding in State.Held do
		if IsHeldId(Holding) then
			table.insert(Kept, Holding)
		else
			Replies.ReplyFailed(Commands, CallIdOf(Holding), Reasons.Closed)
		end
	end
	State.Held = Kept
	TouchWriters(State)
end

local function MustWait(State: State, Call: Call, Clock: number): boolean
	if
		Call.Method == "Id"
		or Call.Method == "Tx"
		or Call.Method == "Resettle"
		or Call.Method == "Erase"
		or Call.Method == "Reset"
	then
		return State.Server.ServerNumber == nil
	end
	if Call.Method == "Apply" or Call.Method == "Edit" or Call.Method == "Commit" then
		return not InFlight.CanWrite(State.Server, Call.Key)
	end
	if Call.Method == "Bump" then
		return ExtrasServer.MustWait(State, Call)
	end
	local Hot = HotServer.HotCallOf(Call)
	if Hot ~= nil then
		return HotServer.MustWait(State, Hot, Clock)
	end
	return false
end

local function IsClosedTo(State: State, Call: Call): boolean
	if Call.Method == "Id" then
		return Closing.IsEnded(State.Sessions) and State.Server.ServerNumber == nil
	end
	return State.Sessions.Shutdown ~= nil
end

local function IsBehindTo(State: State, Call: Call): boolean
	if Call.Method ~= "Apply" and Call.Method ~= "Commit" and Call.Method ~= "Flush" and Call.Method ~= "Refresh" then
		return false
	end
	local Open = State.Sessions.Open[Names.KeyText(Call.Key)]
	return Open ~= nil and Open.IsBehind
end

local function WouldWait(State: State, Call: Call, Clock: number): boolean
	if Call.Method == "CloseAll" or IsClosedTo(State, Call) or IsBehindTo(State, Call) then
		return false
	end
	return MustWait(State, Call, Clock)
end

local function OnId(State: State, Call: IdCall, _Arrived: number, Clock: number, Commands: { Command })
	DrawName(State.Server, Call.CallId, Clock, Commands)
end

local function OnLoad(State: State, Call: LoadCall, _Arrived: number, Clock: number, Commands: { Command })
	local Out = Reads.StartLoad(State.Server, Call, Clock, Commands)
	State.Reads[Out.RequestId] = Out
end

local function OnApply(State: State, Call: ApplyCall, _Arrived: number, Clock: number, Commands: { Command })
	Session.Apply(State.Server, State.Sessions, Call, Clock, Commands)
	Composed.NoteTimersMoved(State, Call.Key)
end

local function OnEdit(State: State, Call: EditCall, Arrived: number, _Clock: number, Commands: { Command })
	Durable.Start(State, Call, Call.MustExist, Arrived, Commands)
end

local function OnCommit(State: State, Call: DurableCall, Arrived: number, _Clock: number, Commands: { Command })
	local Open = State.Sessions.Open[Names.KeyText(Call.Key)]
	if Open == nil then
		return Replies.ReplyFailed(Commands, Call.CallId, Reasons.Closed)
	end
	Durable.Start(State, Call, not Open.MayCreate, Arrived, Commands)
	Open.PushAsked = true
end

local function OnFlush(State: State, Call: KeyCall, _Arrived: number, Clock: number, Commands: { Command })
	Hearing.Flush(State, Call, Clock, Commands)
end

local function OnRefresh(State: State, Call: KeyCall, _Arrived: number, Clock: number, Commands: { Command })
	Hearing.Refresh(State, Call, Clock, Commands)
	Composed.NoteTimersMoved(State, Call.Key)
end

local function OnRelease(State: State, Call: ReleaseCall, _Arrived: number, Clock: number, Commands: { Command })
	Closing.Release(State.Server, State.Sessions, Call, Clock, Commands)
	Showables.Release(State.Server, Call.Key, Composed.ServedOf(State))
	Composed.NoteSendable(State, Call.Key)
end

local function OnTx(State: State, Call: TxCall, Arrived: number, Clock: number, Commands: { Command })
	TxServer.OnCall(State, Call, Arrived, Clock, Commands)
end

local function OnPending(State: State, Call: PendingCall, Arrived: number, Clock: number, Commands: { Command })
	TxServer.OnCall(State, Call, Arrived, Clock, Commands)
end

local function OnResettle(State: State, Call: ResettleCall, Arrived: number, Clock: number, Commands: { Command })
	TxServer.OnCall(State, Call, Arrived, Clock, Commands)
end

local function OnCut(State: State, Call: EraseOrResetCall, Arrived: number, Clock: number, Commands: { Command })
	CutServer.OnCall(State, Call, Arrived, Clock, Commands)
end

local function OnExtras(State: State, Call: ExtrasCall, Arrived: number, Clock: number, Commands: { Command })
	ExtrasServer.OnCall(State, Call, Arrived, Clock, Commands)
end

local function OnHot(State: State, Call: HotCall, Arrived: number, Clock: number, Commands: { Command })
	HotServer.OnCall(State, Call, Arrived, Clock, Commands)
end

local function OnDidApply(State: State, Call: DidApplyCall, _Arrived: number, Clock: number, Commands: { Command })
	local Out = DidApply.DidApply(State.Server, Call, Clock, Commands)
	if Out ~= nil then
		State.Reads[Out.RequestId] = Out
	end
end

local function OnDidApplyWithProbe(
	State: State,
	Call: DidApplyCall,
	_Arrived: number,
	Clock: number,
	Commands: { Command }
)
	local Out = DidApply.DidApplyWithProbe(State.Server, Call, Clock, Commands)
	if Out ~= nil then
		State.Reads[Out.RequestId] = Out
	end
end

local function OnPeek(State: State, Call: PeekCall, _Arrived: number, Clock: number, Commands: { Command })
	local Out = Reads.Start(State.Server, Call, Call.Method, Clock, Commands)
	State.Reads[Out.RequestId] = Out
end

local CallHandlers = {
	Id = OnId,
	Load = OnLoad,
	Apply = OnApply,
	Edit = OnEdit,
	Commit = OnCommit,
	Flush = OnFlush,
	Refresh = OnRefresh,
	Release = OnRelease,
	Tx = OnTx,
	Pending = OnPending,
	Resettle = OnResettle,
	Erase = OnCut,
	Reset = OnCut,
	Bump = OnExtras,
	Total = OnExtras,
	Follow = OnExtras,
	Unfollow = OnExtras,
	Stale = OnExtras,
	PeekWithin = OnExtras,
	Take = OnHot,
	Hold = OnHot,
	Open = OnHot,
	Close = OnHot,
	Confirm = OnHot,
	ReleaseHold = OnHot,
	Deposit = OnHot,
	Withdraw = OnHot,
	DidApply = OnDidApply,
	DidApplyWithProbe = OnDidApplyWithProbe,
	Peek = OnPeek,
	Inspect = OnPeek,
	PeekFresh = OnPeek,
	Losses = OnPeek,
}

type HandledMethod = keyof<typeof(CallHandlers)>

local function OnCall(State: State, Call: Call, Arrived: number, Clock: number, Commands: { Command })
	if Call.Method == "CloseAll" then
		NoteSessionsMoved(State)
		Closing.CloseAll(State.Server, State.Sessions, Call.CallId, Call.BeganAt or Clock, Commands)
		TxServer.CloseAll(State, Commands)
		CutServer.CloseAll(State, Commands)
		return CloseLoads(State, Commands)
	end
	if IsClosedTo(State, Call) then
		return Replies.ReplyFailed(Commands, Call.CallId, Reasons.Closed)
	end
	if IsBehindTo(State, Call) then
		return Replies.ReplyFailed(Commands, Call.CallId, Reasons.Behind)
	end
	if MustWait(State, Call, Clock) then
		local Holding: HeldCall = { Kind = "Held", Call = Call, At = Arrived }
		table.insert(State.Held, Holding)
		return
	end
	local Handler = (CallHandlers :: { [HandledMethod]: CallHandler })[Call.Method]
	Handler(State, Call, Arrived, Clock, Commands)
end

return {
	OnCall = OnCall,
	WouldWait = WouldWait,
	CallIdOf = CallIdOf,
	TouchWriters = TouchWriters,
	AnswerAtEndedClose = AnswerAtEndedClose,
}
