--!strict
--!optimize 2

--[=[
	Call: one Tx call before and as it sends (transaction sheets 7, 15.4 and 17). It answers once, a no with its latest
	name. A non-step call answered Unresolved owes an outcome: its next answer but Unresolved, Busy or Closed, else
	Unresolved when it or the close ends. A followed step hands its next such answer to Hot/Walk/Outcomes.

	Return type: A plain table of functions.
	Example usage:
		Call.Begin(State, Event, Arrived, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Events = require("../../Events")
local Incarnations = require("../../Writing/Incarnations")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Reasons = require("../../Constants/Reasons")
local Replies = require("../../Replies")
local Requests = require("./Requests")
local Shapes = require("../../Shapes")
local Terms = require("./Terms")
local TxState = require("../State")
local Unreadable = require("../../Reading/Unreadable")
local Verify = require("../Work/Verify")
local Work = require("../../Stored/Items/Work")

type Command = Events.Command
type GivenAnswer = Events.Answer
type ReadOutcome = Events.ReadOutcome
type TxCall = Events.TxCall
type StoreKey = Names.StoreKey
type ServerState = Shapes.ServerState
type PinnedRecord = Work.PinnedRecord
type State = Composed.State
type Call = TxState.Call
type NameAndStamp = TxState.NameAndStamp
type Phase = TxState.Phase
type Reason = Reasons.Reason
type Purpose = TxState.Purpose
type PendingCall = TxState.PendingCall
type Waiter = TxState.Waiter
type CallName = Terms.CallName

local NotOutcomes: { [Reason]: true } = {
	[Reasons.Unresolved] = true,
	[Reasons.Busy] = true,
	[Reasons.Closed] = true,
}

local function Ask(State: State, Out: { [string]: number }, Purpose: Purpose, Commands: { Command })
	local RequestId = TxState.NewRequest(State.Server, State.Tx, Purpose)
	Out[Names.KeyText(Purpose.Key)] = RequestId
	local Get: Command = { Kind = "Get", RequestId = RequestId, Target = Purpose.Key }
	table.insert(Commands, Get)
end

local function AskIncarnation(State: State, Pending: PendingCall, Key: StoreKey, Commands: { Command })
	local Purpose: Purpose = { Kind = "IncarnationRead", CallId = Pending.CallId, Key = Key }
	Ask(State, Pending.Out, Purpose, Commands)
end

local function RetryRoundsOf(Server: ServerState, Pending: PendingCall): number
	return Cache.StoreOf(Server, Pending.Legs[Pending.DeciderIndex].Key).Setup.Limits.RetryRounds
end

local function SettlesOutcome(Given: GivenAnswer): boolean
	return Given.Kind == "Succeeded" or NotOutcomes[Given.Reason] == nil
end

local function AnswerLater(Call: Call, Given: GivenAnswer, Commands: { Command })
	if not Call.OwesOutcome or not SettlesOutcome(Given) then
		return
	end
	Call.OwesOutcome = false
	if Call.IsStep then
		Call.Given = Given
		return
	end
	Replies.SettleOutcome(Commands, Call.Decider, Call.CallId, Given)
end

local function Answer(Call: Call, Given: GivenAnswer, Commands: { Command })
	if Call.HasAnswered then
		return AnswerLater(Call, Given, Commands)
	end
	Call.HasAnswered = true
	if Call.IsStep then
		Call.Given = Given
		return
	end
	Call.OwesOutcome = Replies.IsUnresolved(Given)
	Replies.Reply(Commands, Call.CallId, Replies.Named(Given, Replies.GivenNameOf(Call.Name, Call.Stamp)))
end

local function StopOutcome(Call: Call, Commands: { Command })
	if not Call.OwesOutcome or Call.IsStep then
		return
	end
	Call.OwesOutcome = false
	Replies.SettleOutcomeUnresolved(Commands, Call.Decider, Call.CallId)
end

local function End(State: State, Call: Call, Commands: { Command })
	StopOutcome(Call, Commands)
	TxState.EndCall(State.Tx, Call)
end

local function SendTents(State: State, Call: Call, Clock: number, Commands: { Command })
	for _, Key in Call.OtherKeys do
		if not Call.Mine[Names.KeyText(Key)] then
			Requests.SendTent(State, Call, Key, Clock, Commands)
		end
	end
end

local function StartVerification(
	State: State,
	Call: Call,
	Pinned: { PinnedRecord },
	Clock: number,
	Commands: { Command }
)
	local For: Waiter = { Kind = "Call", CallId = Call.CallId }
	Call.Verifying = Verify.StartOwed(State, For, Call.Decider, Pinned, Clock, Commands)
end

local function StartEarlyVerify(State: State, Call: Call, Clock: number, Commands: { Command })
	local Server = State.Server
	local Entry = Cache.FindEntry(Server, Call.Decider)
	if Entry == nil or Entry.Work == nil then
		return
	end
	local Pinned: { PinnedRecord } = {}
	for _, Item in Entry.Work do
		if Item.Kind == "Pinned" then
			table.insert(Pinned, Item)
		end
	end
	if #Pinned < Cache.StoreOf(Server, Call.Decider).Setup.Limits.OwedCap then
		return
	end
	StartVerification(State, Call, Pinned, Clock, Commands)
end

local function NameFor(Server: ServerState, Given: NameAndStamp?, Clock: number): NameAndStamp
	if Given ~= nil then
		return Given
	end
	return { Name = Numbers.DrawnName(Server), Stamp = Clock }
end

local function SendFirstTents(State: State, Call: Call, Clock: number, Commands: { Command })
	StartEarlyVerify(State, Call, Clock, Commands)
	SendTents(State, Call, Clock, Commands)
end

local function OpenCall(State: State, Pending: PendingCall, Starting: Phase): Call
	local Call = TxState.NewCall(Pending, Starting)
	State.Tx.PendingCalls[Pending.CallId] = nil
	State.Tx.Calls[Call.CallId] = Call
	for _, Leg in Call.Legs do
		Requests.TagFor(State.Server, Call, Leg.Key)
	end
	return Call
end

local function StartTents(State: State, Pending: PendingCall, Clock: number, Commands: { Command })
	if Terms.RememberSent(State.Server, Pending, Commands) then
		local Call = OpenCall(State, Pending, "RetryRead")
		local Purpose: Purpose = { Kind = "RetryRead", CallId = Call.CallId, Key = Call.Decider }
		Ask(State, Call.Out, Purpose, Commands)
		return
	end
	SendFirstTents(State, OpenCall(State, Pending, "Tents"), Clock, Commands)
end

local function OpenPending(
	State: State,
	Event: TxCall,
	IsStep: boolean,
	Naming: CallName,
	DeciderIndex: number,
	Arrived: number,
	Clock: number,
	Commands: { Command }
)
	local Server = State.Server
	local Pending: PendingCall = {
		CallId = Event.CallId,
		Legs = Event.Legs,
		DeciderIndex = DeciderIndex,
		Started = Arrived,
		Named = NameFor(Server, Naming.Given, Clock),
		Remembers = Naming.Remembers,
		IsStep = IsStep,
		Out = {},
		Errors = {},
	}
	for _, Leg in Event.Legs do
		if Incarnations.IsUnseen(Server, Leg.Key) then
			AskIncarnation(State, Pending, Leg.Key, Commands)
		end
	end
	if next(Pending.Out) == nil then
		return StartTents(State, Pending, Clock, Commands)
	end
	State.Tx.PendingCalls[Pending.CallId] = Pending
end

local function BeginWith(
	State: State,
	Event: TxCall,
	IsStep: boolean,
	Arrived: number,
	Clock: number,
	Commands: { Command }
)
	local Forms = Terms.ClassifyLegs(State.Server, Event)
	local DeciderIndex = Terms.ChooseDecider(Forms, Event.Hot)
	local Named = Terms.NameOfCall(State.Server, Event, Forms, DeciderIndex)
	OpenPending(State, Event, IsStep, Named, DeciderIndex, Arrived, Clock, Commands)
end

local function Begin(State: State, Event: TxCall, Arrived: number, Clock: number, Commands: { Command })
	BeginWith(State, Event, false, Arrived, Clock, Commands)
end

local function BeginStep(State: State, Event: TxCall, Arrived: number, Clock: number, Commands: { Command })
	BeginWith(State, Event, true, Arrived, Clock, Commands)
end

local function BeginSubStep(
	State: State,
	Event: TxCall,
	Named: NameAndStamp,
	Arrived: number,
	Clock: number,
	Commands: { Command }
)
	local DeciderIndex = Terms.ChooseDecider(Terms.ClassifyLegs(State.Server, Event), Event.Hot)
	local SubName: CallName = { Given = Named }
	OpenPending(State, Event, true, SubName, DeciderIndex, Arrived, Clock, Commands)
end

local function FailPending(State: State, Pending: PendingCall, Why: Reason, Commands: { Command })
	State.Tx.PendingCalls[Pending.CallId] = nil
	if Pending.IsStep then
		State.Tx.StepFailures[Pending.CallId] = Why
		return
	end
	Replies.ReplyFailed(Commands, Pending.CallId, Why)
	if Why == Reasons.Unresolved then
		Replies.SettleOutcomeUnresolved(Commands, Pending.Legs[Pending.DeciderIndex].Key, Pending.CallId)
	end
end

local function OnIncarnationRead(
	State: State,
	Pending: PendingCall,
	Key: StoreKey,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
)
	local Text = Names.KeyText(Key)
	Pending.Out[Text] = nil
	local Server = State.Server
	if Fetched.Kind == "Failed" then
		Pending.Errors[Text] = (Pending.Errors[Text] or 0) + 1
		local IsWithinRounds = Pending.Errors[Text] <= RetryRoundsOf(Server, Pending)
		if IsWithinRounds and not Closing.IsPastDeadline(State.Sessions, Clock) then
			return AskIncarnation(State, Pending, Key, Commands)
		end
		return FailPending(State, Pending, Reasons.Unresolved, Commands)
	end
	local Read = Numbers.LearnStored(Server, Key, Cache.StoreOf(Server, Key).Setup, Fetched, Clock)
	if Read.Kind == "Unreadable" then
		Unreadable.Warn(Server, Key, Read.Cause, Commands)
		return FailPending(State, Pending, Unreadable.ReasonOf(Read.Cause), Commands)
	end
	if next(Pending.Out) == nil then
		StartTents(State, Pending, Clock, Commands)
	end
end

return {
	Begin = Begin,
	BeginStep = BeginStep,
	BeginSubStep = BeginSubStep,
	OnIncarnationRead = OnIncarnationRead,
	Answer = Answer,
	StopOutcome = StopOutcome,
	End = End,
	FailPending = FailPending,
	SendTents = SendTents,
	SendFirstTents = SendFirstTents,
	StartVerification = StartVerification,
}
