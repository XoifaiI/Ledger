--!strict
--!optimize 2

--[=[
	Server: routes extras calls and events. A landed shard value merges into its total's view and paces its writer
	(sheet E3, E4); a landing above a shown q is Stale (E9). The tables point at the owners' handlers, the copies' in
	Copies/Server, whose NextWake keeps Peek bounds through the close. Open Totals and Peeks answer Unresolved then.

	Return type: A plain table with OnCall, MustWait, OnRead, OnMemoryRead, OnMemoryResult, AnswerAtEndedClose,
	OnClock, NextWake and AfterEvent.
	Example usage:
		if not Server.MustWait(State, Call) then Server.OnCall(State, Call, Arrived, Clock, Commands) end
--]=]

local Bump = require("./Totals/Bump")
local Cache = require("../Reading/Cache")
local Closing = require("../Sessions/Closing")
local Composed = require("../Composed")
local CopiesServer = require("./Copies/Server")
local Events = require("../Events")
local ExtrasShapes = require("./Shapes")
local ExtrasState = require("./State")
local KindSetup = require("../Judging/KindSetup")
local Pacing = require("../Writing/Pacing")
local Pairs = require("./Totals/Pairs")
local Record = require("../Constants/Record")
local Refresh = require("./Totals/Refresh")
local Shapes = require("../Shapes")
local Shard = require("./Totals/Shard")
local Stale = require("./Stale")
local Total = require("./Totals/Total")
local Writers = require("../Writing/Writer")

type Command = Events.Command
type MemoryFetched = Events.MemoryFetched
type MemoryOutcome = Events.MemoryOutcome
type SummaryGet = ExtrasState.SummaryGet
type SummaryUpdate = ExtrasState.SummaryUpdate
type Purpose = ExtrasState.Purpose
type ReadHandler = (State, Purpose, number, MemoryFetched, number, number, { Command }) -> ()
type ResultHandler = (State, Purpose, MemoryOutcome, number, { Command }) -> ()
type ReadOutcome = Events.ReadOutcome
type BumpCall = ExtrasShapes.BumpCall
type TotalCall = ExtrasShapes.TotalCall
type ExtrasCall = ExtrasShapes.ExtrasCall
type CallHandler = (State, ExtrasCall, number, number, { Command }) -> ()
type LandedValue = Shapes.LandedValue
type ServerState = Shapes.ServerState
type State = Composed.State

local KeyKinds = Record.KeyKind

local NoLandedBytes = "Server: this call is never made. A ledger key's landing carries the bytes it wrote."

local function OnBump(State: State, Call: BumpCall, Arrived: number, Clock: number, Commands: { Command })
	Bump.StartBump(State, Call, Arrived, Clock, Commands)
end

local function OnTotal(State: State, Call: TotalCall, _Arrived: number, Clock: number, Commands: { Command })
	Total.Begin(State, Call, Clock, Commands)
end

local CallHandlers = {
	Bump = OnBump,
	Total = OnTotal,
	Follow = CopiesServer.OnFollow,
	Unfollow = CopiesServer.OnUnfollow,
	Stale = Stale.OnStale,
	PeekWithin = CopiesServer.OnPeekWithin,
}

type HandledMethod = keyof<typeof(CallHandlers)>

local function OnCall(State: State, Call: ExtrasCall, Arrived: number, Clock: number, Commands: { Command })
	local Handler = (CallHandlers :: { [HandledMethod]: CallHandler })[Call.Method]
	Handler(State, Call, Arrived, Clock, Commands)
end

local function MustWait(State: State, Call: BumpCall): boolean
	return not Bump.CanStart(State.Server, Call)
end

local function MergeShard(State: State, Landed: LandedValue)
	local Ref = Shard.ShardOfKey(Landed.Key)
	local View = ExtrasState.ViewOf(State.Extras, Landed.Key.Store, Landed.Key.Scope, Ref.Total)
	Pairs.MergeLanded(View, Ref.Index, Landed)
end

local function PaceWriter(State: State, Landed: LandedValue, Clock: number)
	local Server = State.Server
	local Writer = Writers.WriterFor(Server, Landed.Key)
	if Writer == nil or Writer.Paced == nil then
		return
	end
	local Bytes = Landed.Bytes
	if Bytes == nil then
		error(NoLandedBytes)
	end
	local Limits = KindSetup.SetupOfKey(Server, Landed.Key).Limits
	Pacing.NoteLanding(Writer.Paced, Landed.Written.Book.Writes, Clock, Bytes, Limits)
	Composed.NoteTimersMovedAt(State, Writer.Text, Landed.Key)
end

local function OnRead(
	State: State,
	RequestId: number,
	Fetched: ReadOutcome,
	Fraction: number,
	Clock: number,
	Commands: { Command }
): boolean
	local Purposes = State.Extras.Purposes
	local Purpose = Purposes[RequestId]
	if Purpose == nil then
		return false
	end
	if Purpose.Kind == "RefreshRead" then
		Purposes[RequestId] = nil
		Refresh.OnKeyRead(State, Purpose.Holder, Purpose.Index, Fetched, Fraction, Clock, Commands)
		return true
	end
	if Purpose.Kind == "TotalKeyRead" then
		Purposes[RequestId] = nil
		Total.OnKeyRead(State, Purpose, RequestId, Fetched, Clock, Commands)
		return true
	end
	return false
end

local function OnSummaryGet(
	State: State,
	Purpose: SummaryGet,
	RequestId: number,
	Fetched: MemoryFetched,
	Fraction: number,
	Clock: number,
	Commands: { Command }
)
	Total.OnSummaryRead(State, Purpose, RequestId, Fetched, Fraction, Clock, Commands)
end

local ReadHandlers = {
	SummaryGet = OnSummaryGet,
	AdviceGet = CopiesServer.OnAdviceGet,
	HeaderGet = CopiesServer.OnHeaderGet,
	PartGet = CopiesServer.OnPartGet,
}

local function OnMemoryRead(
	State: State,
	RequestId: number,
	Fetched: MemoryFetched,
	Fraction: number,
	Clock: number,
	Commands: { Command }
)
	local Purposes = State.Extras.Purposes
	local Purpose = Purposes[RequestId]
	if Purpose == nil then
		return
	end
	local Handler = (ReadHandlers :: { [string]: ReadHandler })[Purpose.Kind]
	if Handler == nil then
		return
	end
	Purposes[RequestId] = nil
	Handler(State, Purpose, RequestId, Fetched, Fraction, Clock, Commands)
end

local function OnSummaryUpdate(
	State: State,
	Purpose: SummaryUpdate,
	Result: MemoryOutcome,
	Clock: number,
	_Commands: { Command }
)
	Refresh.OnResult(State, Purpose.Holder, Result, Clock)
end

local ResultHandlers = {
	SummaryUpdate = OnSummaryUpdate,
	PartSet = CopiesServer.OnPartSet,
	HeaderUpdate = CopiesServer.OnHeaderUpdate,
}

local function OnMemoryResult(
	State: State,
	RequestId: number,
	Result: MemoryOutcome,
	Clock: number,
	Commands: { Command }
)
	local Purposes = State.Extras.Purposes
	local Purpose = Purposes[RequestId]
	if Purpose == nil then
		return
	end
	local Handler = (ResultHandlers :: { [string]: ResultHandler })[Purpose.Kind]
	if Handler == nil then
		if Purpose.Kind == "ItemRemove" then
			Purposes[RequestId] = nil
		end
		return
	end
	Purposes[RequestId] = nil
	Handler(State, Purpose, Result, Clock, Commands)
end

local function OnClock(State: State, Clock: number, Commands: { Command })
	Refresh.OnClock(State, Clock, Commands)
	CopiesServer.OnClock(State, Clock, Commands)
	Total.TimeOut(State, Clock, Commands)
end

local function NextWake(State: State, Clock: number): number?
	local Soonest = Composed.EarliestAfter(Total.NextWake(State, Clock), CopiesServer.NextWake(State, Clock), Clock)
	if State.Sessions.Shutdown ~= nil then
		return Soonest
	end
	return Composed.EarliestAfter(Soonest, Refresh.Soonest(State, Clock), Clock)
end

local function AnswerAtEndedClose(State: State, Clock: number, Commands: { Command })
	if Closing.IsEnded(State.Sessions) then
		Total.AnswerOpenUnresolved(State, Clock, Commands)
		CopiesServer.AnswerOpenUnresolved(State, Commands)
	end
end

local function AfterEvent(State: State, Clock: number, Commands: { Command })
	for _, Landed in State.Server.Landed do
		if Cache.KindOfKey(Landed.Key) == KeyKinds.Shard then
			MergeShard(State, Landed)
		end
		PaceWriter(State, Landed, Clock)
		Stale.NoteLanded(State, Landed, Commands)
	end
	AnswerAtEndedClose(State, Clock, Commands)
end

return {
	OnCall = OnCall,
	MustWait = MustWait,
	OnRead = OnRead,
	OnMemoryRead = OnMemoryRead,
	OnMemoryResult = OnMemoryResult,
	AnswerAtEndedClose = AnswerAtEndedClose,
	OnClock = OnClock,
	NextWake = NextWake,
	AfterEvent = AfterEvent,
}
