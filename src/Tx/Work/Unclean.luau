--!strict
--!optimize 2

--[=[
	Unclean: a read that meets unclean marks reads their deciders (transaction sheet 19, rule 3). All aborted (absent
	or sealed past its bound, for showing only) shows V; committed or fenced ends land in one Resolve. Undecided reads
	again; a Load first fences a held decider due for a session (transaction 5.1). Nothing goes out past the close
	deadline.

	Return type: A plain table of functions.
	Example usage:
		local Next = Unclean.ReadDeciders(State, Out, Kept, Viewed, Marks, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Decision = require("../Legs/Decision")
local Ends = require("../Legs/Ends")
local Events = require("../../Events")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Reads = require("../../Reading/Reads")
local Rides = require("../Rides")
local Shapes = require("../../Shapes")
local Shown = require("../../Reading/Shown")
local Touch = require("./Touch")
local TxShapes = require("../Shapes")
local TxState = require("../State")
local Value = require("../../Stored/Value")
local Work = require("../../Stored/Items/Work")

type Command = Events.Command
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type DeciderSays = Decision.DeciderSays
type MarkOpening = Work.MarkOpening
type Limits = Shapes.Limits
type ServerState = Shapes.ServerState
type StoredRead = Numbers.StoredRead
type StoreKey = Names.StoreKey
type Kept = Value.Kept
type Fields = { [unknown]: unknown }
type End = TxShapes.End
type StandingMark = Work.StandingMark
type Next = Reads.Next
type ReadOut = Reads.ReadOut
type State = Composed.State
type Purpose = TxState.Purpose
type UncleanRead = TxState.UncleanRead
type UncleanReadPurpose = TxState.UncleanReadPurpose
type UncleanFencePurpose = TxState.UncleanFencePurpose
type UncleanResolvePurpose = TxState.UncleanResolvePurpose

local DoneNext: Next = table.freeze({ Kind = "Done" :: "Done" })

local function AskDecider(State: State, Reading: UncleanRead, Blocker: number, Commands: { Command }): boolean
	local Server = State.Server
	local Out = Reading.Out
	local Decider = Names.KeyOfReference(Out.Key, Reading.Marks[Blocker].Decider)
	if Cache.FindStore(Server, Decider) == nil then
		return false
	end
	local Purpose: Purpose = { Kind = "UncleanRead", ReadRequestId = Out.RequestId, Blocker = Blocker, Key = Decider }
	local Get: Command = { Kind = "Get", RequestId = TxState.NewRequest(Server, State.Tx, Purpose), Target = Decider }
	table.insert(Commands, Get)
	return true
end

local function NamesUnholdableDecider(Server: ServerState, Key: StoreKey, Marked: { StandingMark }): boolean
	for _, Mark in Marked do
		if Cache.CannotHold(Server, Names.KeyOfReference(Key, Mark.Decider)) then
			return true
		end
	end
	return false
end

local function LandUnclean(State: State, Reading: UncleanRead, Landed: { End }, Commands: { Command }): Next
	local Out = Reading.Out
	local Purpose: Purpose = { Kind = "UncleanResolve", ReadRequestId = Out.RequestId, Key = Out.Key, Carried = Landed }
	Touch.SendEnds(State, Out.Key, Ends.EndsRequest(Landed), Purpose, Commands)
	return { Kind = "Reading", Out = Out }
end

local function AfterUncleanReads(State: State, Reading: UncleanRead, Clock: number, Commands: { Command }): Next
	local Server = State.Server
	local Out = Reading.Out
	State.Tx.Unclean[Out.RequestId] = nil
	State.Reads[Out.RequestId] = nil
	local Landed: { End } = {}
	local AreAllAborted = true
	for Index, Item in Reading.Marks do
		local Says = Reading.Says[Index]
		if Says == nil then
			AreAllAborted = false
			continue
		end
		if Says.Kind == "Gone" then
			continue
		end
		local End = Decision.ResolveFor(Item, Says)
		if End == nil then
			AreAllAborted = false
		elseif End.Outcome == "Commit" or Reading.Fenced[Index] then
			table.insert(Landed, End)
		else
			Rides.Add(Server, Out.Key, End, Clock)
		end
	end
	if #Landed > 0 then
		if Closing.IsPastDeadline(State.Sessions, Clock) then
			return { Kind = "Reading", Out = Out }
		end
		return LandUnclean(State, Reading, Landed, Commands)
	end
	local Setup = Cache.StoreOf(Server, Out.Key).Setup
	local Context = Composed.ReadContextAt(State, Clock)
	if AreAllAborted then
		if not Shown.IsShown(Server, Out.Key, Reading.Kept.Book.Writes, Reading.Kept.Book.Identity) then
			return Reads.Resume(Server, Out, Context, Commands)
		end
		return Reads.ShowState(Server, Out, Reading.Kept, Reading.Viewed, Reading.Viewed, Context, Commands)
	end
	return Reads.ReadAgainLater(Setup, Out, Context, Commands)
end

local function ReadDeciders(
	State: State,
	Out: ReadOut,
	Kept: Kept,
	Viewed: Fields,
	Marked: { StandingMark },
	Clock: number,
	Commands: { Command }
): Next
	if NamesUnholdableDecider(State.Server, Out.Key, Marked) then
		return Reads.EndRead(Commands, Out, Reads.UnresolvedAnswer)
	end
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return { Kind = "Reading", Out = Out }
	end
	local Reading: UncleanRead = {
		Out = Out,
		Kept = Kept,
		Viewed = Viewed,
		AskedAt = Clock,
		Marks = Marked,
		Says = {},
		Fenced = {},
		Left = 0,
	}
	State.Tx.Unclean[Out.RequestId] = Reading
	for Blocker = 1, #Marked do
		if AskDecider(State, Reading, Blocker, Commands) then
			Reading.Left += 1
		end
	end
	if Reading.Left == 0 then
		return AfterUncleanReads(State, Reading, Clock, Commands)
	end
	return { Kind = "Reading", Out = Out }
end

local function SaysOfDecider(Reading: UncleanRead, Opening: MarkOpening, Read: StoredRead, Limits: Limits): DeciderSays?
	if Read.Kind == "Unreadable" then
		return nil
	end
	if Read.Kind == "Kept" then
		return Decision.DecisionShown(Read.Kept, Opening)
	end
	return Decision.AbsentDeciderSays(Opening, Reading.AskedAt, Limits)
end

local function IsFenceDue(State: State, Reading: UncleanRead, Blocker: number, Read: StoredRead, Clock: number): boolean
	local Says = Reading.Says[Blocker]
	if Read.Kind ~= "Kept" or Says == nil or Says.Kind ~= "Undecided" then
		return false
	end
	local Out = Reading.Out
	if Out.Want.Kind ~= "Load" then
		return false
	end
	return Touch.IsDueForSession(State, Out.Key, Reading.Marks[Blocker], Clock)
end

local function FenceDecider(
	State: State,
	Reading: UncleanRead,
	Blocker: number,
	Decider: StoreKey,
	Commands: { Command }
)
	local Fence = Decision.FenceFor(Reading.Marks[Blocker])
	local Purpose: Purpose =
		{ Kind = "UncleanFence", ReadRequestId = Reading.Out.RequestId, Blocker = Blocker, Key = Decider }
	Touch.SendEnds(State, Decider, Ends.EndsRequest({ Fence }), Purpose, Commands)
	Reading.Fenced[Blocker] = true
end

local function LiveReading(State: State, ReadRequestId: number): UncleanRead?
	local Tx = State.Tx
	local Reading = Tx.Unclean[ReadRequestId]
	if Reading == nil then
		return nil
	end
	local Out = Reading.Out
	if State.Reads[Out.RequestId] ~= Out then
		Tx.Unclean[ReadRequestId] = nil
		return nil
	end
	return Reading
end

local function BlockerHeard(State: State, Reading: UncleanRead, Clock: number, Commands: { Command }): Next
	Reading.Left -= 1
	if Reading.Left > 0 then
		return DoneNext
	end
	return AfterUncleanReads(State, Reading, Clock, Commands)
end

local function OnUncleanRead(
	State: State,
	Purpose: UncleanReadPurpose,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
): Next
	local Reading = LiveReading(State, Purpose.ReadRequestId)
	if Reading == nil then
		return DoneNext
	end
	if Fetched.Kind ~= "Failed" then
		local Server = State.Server
		local Setup = Cache.StoreOf(Server, Purpose.Key).Setup
		local Read = Numbers.LearnStored(Server, Purpose.Key, Setup, Fetched, Clock)
		local Opening = Reading.Marks[Purpose.Blocker].Opening
		Reading.Says[Purpose.Blocker] = SaysOfDecider(Reading, Opening, Read, Setup.Limits)
		if IsFenceDue(State, Reading, Purpose.Blocker, Read, Clock) then
			FenceDecider(State, Reading, Purpose.Blocker, Purpose.Key, Commands)
			return DoneNext
		end
	end
	return BlockerHeard(State, Reading, Clock, Commands)
end

local function OnUncleanFence(
	State: State,
	Purpose: UncleanFencePurpose,
	Result: Outcome,
	Clock: number,
	Commands: { Command }
): Next
	local Reading = LiveReading(State, Purpose.ReadRequestId)
	if Reading == nil then
		return DoneNext
	end
	if Result.Kind ~= "Err" then
		Numbers.SeeLeftOver(State.Server, Purpose.Key, Result.Note)
	end
	Reading.Says[Purpose.Blocker] = Decision.FenceSays(Ends.LoneEndReport(Result))
	return BlockerHeard(State, Reading, Clock, Commands)
end

local function OnUncleanResolve(
	State: State,
	Purpose: UncleanResolvePurpose,
	Result: Outcome,
	Clock: number,
	Commands: { Command }
): Next
	local Out = State.Reads[Purpose.ReadRequestId]
	if Out == nil then
		return DoneNext
	end
	State.Reads[Out.RequestId] = nil
	local Context = Composed.ReadContextAt(State, Clock)
	local Setup = Cache.StoreOf(State.Server, Out.Key).Setup
	if Result.Kind == "Nil" then
		return Reads.ReadAgainLater(Setup, Out, Context, Commands)
	end
	local Next = Reads.OnUpdateResult(State.Server, Out, Result, Context, Commands)
	if Next.Kind ~= "Deciders" then
		return Next
	end
	return Reads.ShowState(State.Server, Out, Next.Kept, Next.Viewed, Next.Viewed, Context, Commands)
end

return {
	ReadDeciders = ReadDeciders,
	OnUncleanRead = OnUncleanRead,
	OnUncleanFence = OnUncleanFence,
	OnUncleanResolve = OnUncleanResolve,
}
