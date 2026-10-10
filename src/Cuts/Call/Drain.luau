--!strict
--!optimize 2

--[=[
	Drain: what a cut does with the marks it met (cuts sheet 8.3): a fence to each reachable decider, each decision
	as a ride, an orphan read for a missing decider, an erase's pinned records verified. The cut goes again once
	nothing is out, after a wait if nothing was decided. An unreachable decider warns once per call.

	Return type: A plain table with Start, OnFence, OrphanReadsDue, OnOrphanRead, OnVerified, WaitDue,
	IsRoundWithoutProgress and NextWake.
	Example usage:
		Drain.Start(State, Cutting, Report.Marks, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Call = require("./Call")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local CutState = require("../State")
local Decision = require("../../Tx/Legs/Decision")
local Ends = require("../../Tx/Legs/Ends")
local Events = require("../../Events")
local JudgingShapes = require("../../Judging/Shapes")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Rides = require("../../Tx/Rides")
local Sending = require("../../Writing/Sending")
local TxShapes = require("../../Tx/Shapes")
local TxState = require("../../Tx/State")
local Verify = require("../../Tx/Work/Verify")
local Work = require("../../Stored/Items/Work")

type Command = Events.Command
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type StoreKey = Names.StoreKey
type End = TxShapes.End
type Report = JudgingShapes.Report
type Mark = Work.Mark
type PinnedRecord = Work.PinnedRecord
type StandingMark = Work.StandingMark
type State = Composed.State
type Waiter = TxState.Waiter
type CutCall = CutState.CutCall
type Drain = CutState.Drain
type Purpose = CutState.Purpose

type Group = { read Decider: StoreKey, read Indexes: { number } }

local UnreachableDecider = "a cut met a mark whose decider this server cannot reach: its store is not opened here, "
	.. "or cannot hold that key. Only a server that reaches the decider settles the mark, when it touches the key. "
	.. "Until then the cut makes no progress, and it stops a few rounds after it answers."

local function DeciderOf(Cutting: CutCall, Mark: StandingMark): StoreKey
	return Names.KeyOfReference(Cutting.Key, Mark.Decider)
end

local function ByDecider(Cutting: CutCall, Standing: { StandingMark }): { Group }
	local Groups: { Group } = {}
	local Found: { [string]: Group } = {}
	for Index, Mark in Standing do
		local Decider = DeciderOf(Cutting, Mark)
		local Text = Names.KeyText(Decider)
		local Grouped = Found[Text]
		if Grouped == nil then
			Grouped = { Decider = Decider, Indexes = {} }
			Found[Text] = Grouped
			table.insert(Groups, Grouped)
		end
		table.insert(Grouped.Indexes, Index)
	end
	return Groups
end

local function OrphanAgeOf(State: State, Cutting: CutCall): number
	return Cache.StoreOf(State.Server, Cutting.Key).Setup.Limits.OrphanAge
end

local function IsAwaitingRead(Draining: Drain, Index: number): boolean
	return Draining.FenceMissing[Index] == true and Draining.AskedAt[Index] == nil
end

local function IsReadDue(Draining: Drain, Index: number, Clock: number, OrphanAge: number): boolean
	return IsAwaitingRead(Draining, Index) and Clock - Draining.Marks[Index].Opening.Stamp >= OrphanAge
end

local function EarliestRead(State: State, Cutting: CutCall, Draining: Drain): number?
	local OrphanAge = OrphanAgeOf(State, Cutting)
	local Earliest: number? = nil
	for Index, Mark in Draining.Marks do
		if IsAwaitingRead(Draining, Index) then
			local DueAt = Mark.Opening.Stamp + OrphanAge
			if Earliest == nil or DueAt < Earliest then
				Earliest = DueAt
			end
		end
	end
	return Earliest
end

local function SendFence(
	State: State,
	Cutting: CutCall,
	Draining: Drain,
	Group: Group,
	Clock: number,
	Commands: { Command }
)
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Fences: { End } = {}
	for _, Index in Group.Indexes do
		table.insert(Fences, Decision.FenceFor(Draining.Marks[Index]))
	end
	local Purpose: Purpose = { Kind = "Fence", CallId = Cutting.CallId, Decider = Group.Decider, Key = Cutting.Key }
	local RequestId = CutState.NewRequest(State.Server, State.Cuts, Purpose)
	Draining.Fences[Names.KeyText(Group.Decider)] = RequestId
	local Update: Command =
		{ Kind = "Update", RequestId = RequestId, Target = Group.Decider, Request = Ends.EndsRequest(Fences) }
	table.insert(Commands, Update)
end

local function AskOrphanRead(
	State: State,
	Cutting: CutCall,
	Draining: Drain,
	Index: number,
	Clock: number,
	Commands: { Command }
)
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Decider = DeciderOf(Cutting, Draining.Marks[Index])
	local Purpose: Purpose = { Kind = "OrphanRead", CallId = Cutting.CallId, Mark = Index, Key = Decider }
	local RequestId = CutState.NewRequest(State.Server, State.Cuts, Purpose)
	Draining.Reads[Index] = RequestId
	Draining.AskedAt[Index] = Clock
	local Get: Command = { Kind = "Get", RequestId = RequestId, Target = Decider }
	table.insert(Commands, Get)
end

local function OrphanReadsDue(State: State, Cutting: CutCall, Clock: number, Commands: { Command })
	local Draining = Cutting.Drain
	if Draining == nil or Cutting.Phase ~= "Draining" then
		return
	end
	local OrphanAge = OrphanAgeOf(State, Cutting)
	for Index = 1, #Draining.Marks do
		if IsReadDue(Draining, Index, Clock, OrphanAge) then
			AskOrphanRead(State, Cutting, Draining, Index, Clock, Commands)
		end
	end
end

local function WaitOutQuietRound(State: State, Cutting: CutCall, Draining: Drain, Clock: number)
	Cutting.QuietRounds += 1
	local Limits = Cache.StoreOf(State.Server, Cutting.Key).Setup.Limits
	local Until = Clock + Sending.RetryGap(Cutting.QuietRounds, Limits)
	local Due = EarliestRead(State, Cutting, Draining)
	if Due ~= nil and Due > Until then
		Until = Due
	end
	Cutting.WaitUntil = Until
end

local function AskOrSend(State: State, Cutting: CutCall, Clock: number, Commands: { Command })
	local Draining = Cutting.Drain
	if Draining == nil or CutState.IsOutstanding(Draining) then
		return
	end
	OrphanReadsDue(State, Cutting, Clock, Commands)
	if CutState.IsOutstanding(Draining) then
		return
	end
	if Draining.Decided then
		Cutting.QuietRounds = 0
		return Call.SendCut(State, Cutting, Clock, Commands)
	end
	local Waited = Cutting.WaitUntil
	if Waited == nil then
		return WaitOutQuietRound(State, Cutting, Draining, Clock)
	end
	if Clock >= Waited then
		Call.SendCut(State, Cutting, Clock, Commands)
	end
end

local function WaitDue(State: State, Cutting: CutCall, Clock: number, Commands: { Command })
	local Waited = Cutting.WaitUntil
	if Cutting.Phase == "Draining" and Waited ~= nil and Clock >= Waited then
		AskOrSend(State, Cutting, Clock, Commands)
	end
end

local function WarnUnreachable(Cutting: CutCall, Commands: { Command })
	if Cutting.HasWarnedUnreachable then
		return
	end
	Cutting.HasWarnedUnreachable = true
	local Warn: Command = { Kind = "Warn", Key = Cutting.Key, Text = UnreachableDecider }
	table.insert(Commands, Warn)
end

local function Start(State: State, Cutting: CutCall, Listed: { Mark }, Clock: number, Commands: { Command })
	local Draining: Drain = {
		Fences = {},
		Marks = {},
		FenceMissing = {},
		AskedAt = {},
		Reads = {},
		VerifyId = nil,
		Decided = false,
		HasErredFence = false,
	}
	local Pinned: { PinnedRecord } = {}
	for _, Item in Listed do
		if Item.Kind == "Pinned" then
			table.insert(Pinned, Item)
		else
			table.insert(Draining.Marks, Item)
		end
	end
	Cutting.Drain = Draining
	Cutting.Phase = "Draining"
	for _, Group in ByDecider(Cutting, Draining.Marks) do
		if not Cache.IsReachable(State.Server, Group.Decider) then
			WarnUnreachable(Cutting, Commands)
			continue
		end
		SendFence(State, Cutting, Draining, Group, Clock, Commands)
	end
	if #Pinned > 0 then
		local For: Waiter = { Kind = "Cut", CallId = Cutting.CallId }
		Draining.VerifyId = Verify.Start(State, For, Cutting.Key, Pinned, Clock, Commands)
	end
	AskOrSend(State, Cutting, Clock, Commands)
end

local function TakeFenceReports(State: State, Cutting: CutCall, Draining: Drain, Group: Group, Reports: { Report })
	for Position, Index in Group.Indexes do
		local Report = Reports[Position]
		if Report ~= nil and Report.Kind == "Missing" then
			Draining.FenceMissing[Index] = true
		end
		local Resolve = Decision.ResolveFor(Draining.Marks[Index], Decision.FenceSays(Report))
		if Resolve ~= nil then
			Rides.AddForCall(State.Server, Cutting.Key, Resolve, Cutting.CallId)
			Draining.Decided = true
		end
	end
end

local function OnFence(
	State: State,
	Cutting: CutCall,
	Decider: StoreKey,
	Result: Outcome,
	Clock: number,
	Commands: { Command }
)
	local Draining = Cutting.Drain
	if Draining == nil then
		return
	end
	local Text = Names.KeyText(Decider)
	Draining.Fences[Text] = nil
	if Result.Kind == "Err" then
		Draining.HasErredFence = true
		return AskOrSend(State, Cutting, Clock, Commands)
	end
	Numbers.SeeLeftOver(State.Server, Decider, Result.Note)
	for _, Group in ByDecider(Cutting, Draining.Marks) do
		if Names.KeyText(Group.Decider) ~= Text then
			continue
		end
		TakeFenceReports(State, Cutting, Draining, Group, Result.Note.EndReports)
	end
	AskOrSend(State, Cutting, Clock, Commands)
end

local function RideOrphanEnd(
	State: State,
	Cutting: CutCall,
	Draining: Drain,
	Index: number,
	Fetched: ReadOutcome,
	Clock: number
)
	if Fetched.Kind == "Failed" then
		return
	end
	local Server = State.Server
	local Mark = Draining.Marks[Index]
	local Decider = DeciderOf(Cutting, Mark)
	local Read = Numbers.LearnStored(Server, Decider, Cache.StoreOf(Server, Decider).Setup, Fetched, Clock)
	if Read.Kind == "Unreadable" then
		return
	end
	local Says = Decision.DecisionShown(if Read.Kind == "Kept" then Read.Kept else nil, Mark.Opening)
	if
		not Decision.IsOrphanEvidence(Says, Draining.AskedAt[Index], Mark.Opening.Stamp, OrphanAgeOf(State, Cutting))
	then
		return
	end
	Rides.AddForCall(Server, Cutting.Key, Decision.OrphanEnd(Mark), Cutting.CallId)
	Draining.Decided = true
end

local function OnOrphanRead(
	State: State,
	Cutting: CutCall,
	Index: number,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
)
	local Draining = Cutting.Drain
	if Draining == nil then
		return
	end
	Draining.Reads[Index] = nil
	RideOrphanEnd(State, Cutting, Draining, Index, Fetched, Clock)
	AskOrSend(State, Cutting, Clock, Commands)
end

local function OnVerified(State: State, CallId: number, Clock: number, Commands: { Command })
	local Cutting = CutState.FindCall(State.Cuts, CallId)
	if Cutting == nil or Cutting.Drain == nil then
		return
	end
	Cutting.Drain.VerifyId = nil
	if Rides.CarriesDrop(State.Server, Cutting.Key, Clock, Call.CarrierOf(Cutting)) then
		Cutting.Drain.Decided = true
	end
	AskOrSend(State, Cutting, Clock, Commands)
end

local function IsRoundWithoutProgress(State: State, Cutting: CutCall): boolean
	local Draining = Cutting.Drain
	if Draining == nil or Draining.Decided or Draining.HasErredFence then
		return false
	end
	return EarliestRead(State, Cutting, Draining) == nil
end

local function IsDue(State: State, Cutting: CutCall, Clock: number): boolean
	if Cutting.Phase ~= "Draining" then
		return false
	end
	if Composed.IsReached(Cutting.WaitUntil, Clock) then
		return true
	end
	local Draining = Cutting.Drain
	return Draining ~= nil and Composed.IsReached(EarliestRead(State, Cutting, Draining), Clock)
end

local function NextWake(State: State, Cutting: CutCall, Clock: number): number?
	local Draining = Cutting.Drain
	if Draining == nil or Cutting.Phase ~= "Draining" then
		return nil
	end
	local Soonest = Composed.EarliestAfter(nil, Cutting.WaitUntil, Clock)
	return Composed.EarliestAfter(Soonest, EarliestRead(State, Cutting, Draining), Clock)
end

return {
	Start = Start,
	OnFence = OnFence,
	OrphanReadsDue = OrphanReadsDue,
	OnOrphanRead = OnOrphanRead,
	OnVerified = OnVerified,
	WaitDue = WaitDue,
	IsRoundWithoutProgress = IsRoundWithoutProgress,
	IsDue = IsDue,
	NextWake = NextWake,
}
