--!strict
--!optimize 2

--[=[
	InFlight: a server's reads in flight, kept in State.Reads by request id: a result handed to Reads, what its Next
	asks, timers, and the session a Load opens. Tx/Unclean takes Deciders, CopyReads a copy's read, and Tx/Touch the
	marks of a Load shown at once. A read answers Unresolved at OpBound after its start, even while waiting for a help.

	Return type: A plain table with CanWrite, OpenSession, ActOnNext, OnReadResult, OnUpdateResult, TakeIdleReader,
	BoundOf and TickReads.
	Example usage:
		local Out = State.Reads[RequestId]
		if Out ~= nil then InFlight.OnReadResult(State, Out, Fetched, Clock, Commands) end
--]=]

local Cache = require("./Cache")
local Composed = require("../Composed")
local Events = require("../Events")
local Hearing = require("../Writing/Hearing")
local Help = require("../Tx/Work/Help")
local JudgingShapes = require("../Judging/Shapes")
local Names = require("../Encoding/Names")
local Reads = require("./Reads")
local Reasons = require("../Constants/Reasons")
local Replies = require("../Replies")
local Sending = require("../Writing/Sending")
local Session = require("../Sessions/Session")
local Shapes = require("../Shapes")
local Sorted = require("../Sorted")
local Touch = require("../Tx/Work/Touch")
local Unclean = require("../Tx/Work/Unclean")
local Writers = require("../Writing/Writer")

type Command = Events.Command
type EndWorkReport = JudgingShapes.EndWorkReport
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type StoreKey = Names.StoreKey
type Next = Reads.Next
type Opened = Reads.Opened
type OpenedEmpty = Reads.OpenedEmpty
type ReadOut = Reads.ReadOut
type Session = Session.Session
type SessionState = Session.SessionState
type ServerState = Shapes.ServerState
type State = Composed.State

local function CanWrite(Server: ServerState, Key: StoreKey): boolean
	if Writers.WriterFor(Server, Key) ~= nil then
		return true
	end
	return Writers.CanStartWriter(Server, Key)
end

local function OpenSession(State: State, Found: Opened | OpenedEmpty, Clock: number, Commands: { Command })
	local Server = State.Server
	if State.Sessions.Shutdown ~= nil then
		return Replies.ReplyFailed(Commands, Found.Out.CallId, Reasons.Closed)
	end
	if not CanWrite(Server, Found.Out.Key) then
		table.insert(State.Held, Found)
		return
	end
	Composed.NoteTimersMoved(State, Found.Out.Key)
	if Found.Kind == "OpenedEmpty" then
		return Session.LoadEmpty(Server, State.Sessions, Found, Clock, Commands)
	end
	Session.Load(Server, State.Sessions, Found, Clock, Commands)
	Hearing.WarnIfLarge(State, Found.Out.Key, Found.Kept, Commands)
end

local function WaitToEndWork(State: State, Out: ReadOut, Report: EndWorkReport, Clock: number, Commands: { Command })
	local Limits = Cache.StoreOf(State.Server, Out.Key).Setup.Limits
	Out.ErrorsInARow += 1
	Out.RetryAt = math.min(Clock + Sending.RetryGap(Out.ErrorsInARow, Limits), Out.Started + Limits.OpBound)
	State.Reads[Out.RequestId] = Out
	Help.EndWork(State, { Kind = "Read", ReadRequestId = Out.RequestId }, Out.Key, Report, Clock, Commands)
end

local function ActForLoad(State: State, Next: Next, Clock: number, Commands: { Command })
	if Next.Kind == "Opened" and Next.Out.Want.Kind == "Load" then
		Touch.ActForSession(State, Next.Out.Key, Clock, Commands)
	end
end

local function ActOnNext(State: State, Next: Next, Clock: number, Commands: { Command })
	if Next.Kind == "Done" then
		return
	end
	if Next.Kind == "Reading" then
		State.Reads[Next.Out.RequestId] = Next.Out
		return
	end
	if Next.Kind == "EndWork" then
		return WaitToEndWork(State, Next.Out, Next.Report, Clock, Commands)
	end
	if Next.Kind == "Deciders" then
		return ActOnNext(
			State,
			Unclean.ReadDeciders(State, Next.Out, Next.Kept, Next.Viewed, Next.Marks, Clock, Commands),
			Clock,
			Commands
		)
	end
	if Next.Kind == "Handed" or (Next.Kind == "Opened" and Reads.IsHanded(Next.Out.Want)) then
		table.insert(State.Extras.CopyReads, Next)
		return
	end
	OpenSession(State, Next, Clock, Commands)
end

local function OnReadResult(State: State, Out: ReadOut, Fetched: ReadOutcome, Clock: number, Commands: { Command })
	State.Reads[Out.RequestId] = nil
	local Context = Composed.ReadContextAt(State, Clock)
	local Next = Reads.OnReadResult(State.Server, Out, Fetched, Context, Commands)
	ActForLoad(State, Next, Clock, Commands)
	ActOnNext(State, Next, Clock, Commands)
end

local function OnUpdateResult(State: State, Out: ReadOut, Result: Outcome, Clock: number, Commands: { Command })
	State.Reads[Out.RequestId] = nil
	local Context = Composed.ReadContextAt(State, Clock)
	local Next = Reads.OnUpdateResult(State.Server, Out, Result, Context, Commands)
	ActForLoad(State, Next, Clock, Commands)
	ActOnNext(State, Next, Clock, Commands)
end

local function TakeIdleReader(Sessions: SessionState, RequestId: number): Session?
	local Text = Sessions.IdleReads[RequestId]
	if Text == nil then
		return nil
	end
	Sessions.IdleReads[RequestId] = nil
	local Open = Sessions.Open[Text]
	if Open == nil or Open.IdleOut ~= RequestId then
		return nil
	end
	return Open
end

local function BoundOf(Server: ServerState, Out: ReadOut): number
	return Out.Started + Cache.StoreOf(Server, Out.Key).Setup.Limits.OpBound
end

local function TickReads(State: State, Clock: number, Commands: { Command })
	local Server = State.Server
	local Due: { ReadOut } = {}
	for _, RequestId in Sorted.SortedIds(State.Reads) do
		local Out = State.Reads[RequestId]
		if Out == nil then
			continue
		end
		if Out.RetryAt ~= nil and Clock >= Out.RetryAt and Out.HelpId == nil then
			table.insert(Due, Out)
		else
			local Next = Reads.TimeOut(Server, Out, Clock, Commands)
			if Next.Kind ~= "Reading" then
				State.Reads[RequestId] = nil
				ActOnNext(State, Next, Clock, Commands)
			end
		end
	end
	local Context = Composed.ReadContextAt(State, Clock)
	for _, Out in Due do
		State.Reads[Out.RequestId] = nil
		local Next = Reads.Resume(Server, Out, Context, Commands)
		ActOnNext(State, Next, Clock, Commands)
	end
end

return {
	CanWrite = CanWrite,
	OpenSession = OpenSession,
	ActOnNext = ActOnNext,
	OnReadResult = OnReadResult,
	OnUpdateResult = OnUpdateResult,
	TakeIdleReader = TakeIdleReader,
	BoundOf = BoundOf,
	TickReads = TickReads,
}
