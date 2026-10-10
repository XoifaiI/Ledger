--!strict
--!optimize 2

--[=[
	NextSteps: what a Tx call sends or waits for after a report: the Tents, Commit or final fence again, a help, the
	verification of owed records, a gate waited out (transaction sheets 15.1, 15.2, 16, 17, cuts 8.4). A clean call
	whose rounds end on NoRoom answers NoRoom. SendAgainLater waits the growing retry gap and counts no round.

	Return type: A plain table of functions.
	Example usage:
		NextSteps.FenceFinal(State, Call, Clock, Commands)
--]=]

local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Events = require("../../Events")
local Help = require("../Work/Help")
local Helper = require("../../Cuts/Call/Helper")
local JudgingShapes = require("../../Judging/Shapes")
local Names = require("../../Encoding/Names")
local Reasons = require("../../Constants/Reasons")
local Requests = require("./Requests")
local Seal = require("../../Stored/Items/Seal")
local Sending = require("../../Writing/Sending")
local TxCalls = require("./Call")
local TxState = require("../State")
local Work = require("../../Stored/Items/Work")

type Command = Events.Command
type StoreKey = Names.StoreKey
type EndWorkReport = JudgingShapes.EndWorkReport
type Gate = Seal.Gate
type Mark = Work.Mark
type PinnedRecord = Work.PinnedRecord
type State = Composed.State
type Call = TxState.Call
type Purpose = TxState.Purpose
type Waiter = TxState.Waiter

export type BlockedKey = { read Key: StoreKey, read Report: EndWorkReport }

local RoutingFault = "NextSteps: this call is never made."
local NoGatedKey = `{RoutingFault} A call waiting out a gate has a Gated report on its Commit or one of its Tents. `
	.. "The core routed it wrongly."

local function FenceFinal(State: State, Call: Call, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	Call.Phase = "FinalFence"
	local Purpose: Purpose = { Kind = "FinalFence", CallId = Call.CallId, Key = Call.Decider }
	Requests.Issue(State, Call, Requests.FenceRequest(Call, true), Purpose, Commands)
end

local function SendCommit(State: State, Call: Call, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	Call.Phase = "Commit"
	local Request = Requests.CommitRequest(State.Server, Call, Clock)
	local Purpose: Purpose = { Kind = "Commit", CallId = Call.CallId, Key = Call.Decider, Carried = Request.Ends }
	Requests.Issue(State, Call, Request, Purpose, Commands)
end

local function SendTentsAgain(State: State, Call: Call, Clock: number, Commands: { Command })
	Call.Phase = "Tents"
	TxCalls.SendTents(State, Call, Clock, Commands)
end

local function AreAllMine(Call: Call): boolean
	for _, Key in Call.OtherKeys do
		if not Call.Mine[Names.KeyText(Key)] then
			return false
		end
	end
	return true
end

local function StartCommit(State: State, Call: Call, Clock: number, Commands: { Command })
	if Call.Verifying ~= nil then
		Call.Phase = "Verifying"
		return
	end
	SendCommit(State, Call, Clock, Commands)
end

local function SendBlockedAgain(State: State, Call: Call, Clock: number, Commands: { Command })
	if AreAllMine(Call) then
		return StartCommit(State, Call, Clock, Commands)
	end
	SendTentsAgain(State, Call, Clock, Commands)
end

local function IsHelping(State: State, Call: Call): boolean
	for _, Helping in State.Tx.Helps do
		if Helping.For.Kind == "Call" and Helping.For.CallId == Call.CallId then
			return true
		end
	end
	return false
end

local function AfterHelped(State: State, Call: Call, Clock: number, Commands: { Command })
	if Call.Phase ~= "Helping" or IsHelping(State, Call) then
		return
	end
	SendBlockedAgain(State, Call, Clock, Commands)
end

local function HoldsNoRoom(Blocked: { BlockedKey }): boolean
	for _, Each in Blocked do
		if Each.Report.Kind == "NoRoom" then
			return true
		end
	end
	return false
end

local function GiveUpHelping(State: State, Call: Call, Blocked: { BlockedKey }, Clock: number, Commands: { Command })
	if Call.IsUnclean or not HoldsNoRoom(Blocked) then
		return FenceFinal(State, Call, Clock, Commands)
	end
	TxCalls.Answer(Call, { Kind = "Failed", Reason = Reasons.NoRoom, State = nil, Identity = nil }, Commands)
	TxCalls.End(State, Call, Commands)
end

local function HelpWith(State: State, Call: Call, Blocked: { BlockedKey }, Clock: number, Commands: { Command })
	if Call.Rounds >= Requests.LimitsOf(State.Server, Call).RetryRounds then
		return GiveUpHelping(State, Call, Blocked, Clock, Commands)
	end
	Call.Rounds += 1
	Call.Phase = "Helping"
	local For: Waiter = { Kind = "Call", CallId = Call.CallId }
	for _, Each in Blocked do
		Help.StartHelp(State, For, Each.Key, Each.Report, Clock, Commands)
	end
	AfterHelped(State, Call, Clock, Commands)
end

local function AfterVerified(State: State, Call: Call, Clock: number, Commands: { Command })
	Call.Verifying = nil
	if Call.Phase == "Verifying" then
		SendCommit(State, Call, Clock, Commands)
	end
end

local function AfterOwed(State: State, Call: Call, Listed: { Mark }, Clock: number, Commands: { Command })
	if Call.Rounds >= Requests.LimitsOf(State.Server, Call).RetryRounds then
		return FenceFinal(State, Call, Clock, Commands)
	end
	Call.Rounds += 1
	Call.Phase = "Verifying"
	local Pinned: { PinnedRecord } = {}
	for _, Item in Listed do
		if Item.Kind == "Pinned" then
			table.insert(Pinned, Item)
		end
	end
	TxCalls.StartVerification(State, Call, Pinned, Clock, Commands)
	if Call.Verifying == nil then
		SendCommit(State, Call, Clock, Commands)
	end
end

local function GatedKeyOf(Call: Call): StoreKey
	if Call.GatedAt == "Commit" then
		return Call.Decider
	end
	for _, Key in Call.OtherKeys do
		local Report = Call.TentReports[Names.KeyText(Key)]
		if Report ~= nil and Report.Kind == "Gated" then
			return Key
		end
	end
	error(NoGatedKey)
end

local function FinishGateOf(State: State, Call: Call, KeyGate: Gate, Clock: number, Commands: { Command })
	Call.WaitUntil = nil
	Helper.FinishGate(State, GatedKeyOf(Call), KeyGate, { Kind = "Tx", CallId = Call.CallId }, Clock, Commands)
end

local function WaitOutGate(State: State, Call: Call, KeyGate: Gate, Clock: number, Commands: { Command })
	local Limits = Requests.LimitsOf(State.Server, Call)
	if Call.Rounds >= Limits.RetryRounds then
		return FenceFinal(State, Call, Clock, Commands)
	end
	Call.Rounds += 1
	Call.GatedAt = if Call.Phase == "Commit" then "Commit" else "Tents"
	Call.Gate = KeyGate
	Call.Phase = "GateWait"
	local SettledAt = KeyGate.PlacedAt + Limits.SettleAge
	if Clock >= SettledAt then
		return FinishGateOf(State, Call, KeyGate, Clock, Commands)
	end
	Call.WaitUntil = SettledAt
end

local function GateWaitDue(State: State, Call: Call, Clock: number, Commands: { Command })
	local KeyGate = Call.Gate
	local Due = Call.WaitUntil
	if Call.Phase == "GateWait" and KeyGate ~= nil and Due ~= nil and Clock >= Due then
		FinishGateOf(State, Call, KeyGate, Clock, Commands)
	end
end

local function SendAgainLater(State: State, Call: Call, Clock: number)
	Call.Resends += 1
	Call.ResendAt = Clock + Sending.RetryGap(Call.Resends, Requests.LimitsOf(State.Server, Call))
end

local function HasTimerReached(Call: Call, Clock: number): boolean
	local Resolving = Call.Resolving
	if Resolving ~= nil and Composed.IsReached(Resolving.RidesDueAt, Clock) then
		return true
	end
	return Composed.IsReached(Call.WaitUntil, Clock) or Composed.IsReached(Call.ResendAt, Clock)
end

local function ResendDue(State: State, Call: Call, Clock: number, Commands: { Command })
	local Due = Call.ResendAt
	if Due == nil or Clock < Due then
		return
	end
	Call.ResendAt = nil
	if Call.Phase == "Commit" then
		return SendCommit(State, Call, Clock, Commands)
	end
	SendTentsAgain(State, Call, Clock, Commands)
end

local function AfterGate(State: State, Call: Call, Clock: number, Commands: { Command })
	if Call.Phase ~= "GateWait" then
		return
	end
	local At = Call.GatedAt
	Call.Gate = nil
	Call.GatedAt = nil
	if At == "Commit" then
		return SendCommit(State, Call, Clock, Commands)
	end
	SendTentsAgain(State, Call, Clock, Commands)
end

return {
	FenceFinal = FenceFinal,
	SendCommit = SendCommit,
	SendTentsAgain = SendTentsAgain,
	AreAllMine = AreAllMine,
	StartCommit = StartCommit,
	HelpWith = HelpWith,
	AfterHelped = AfterHelped,
	AfterVerified = AfterVerified,
	AfterOwed = AfterOwed,
	WaitOutGate = WaitOutGate,
	GateWaitDue = GateWaitDue,
	AfterGate = AfterGate,
	SendAgainLater = SendAgainLater,
	HasTimerReached = HasTimerReached,
	ResendDue = ResendDue,
}
