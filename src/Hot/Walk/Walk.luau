--!strict
--!optimize 2

--[=[
	Walk: a Take or Hold's walk over a quantity's parts (sheet H3, H6). A named Take goes by hash order, fencing a
	part the view shows passed, and remembers its name once its first step is accepted; other walks go by the view,
	which answers SoldOut or Busy from memory. A Tx step waits for the one before to close. A Take with legs reads its
	first part before it sends anything unless the view shows it, and answers Missing, sending nothing, for a part
	read absent within ViewAge: a step would mark the legs' keys for a part that does not exist.

	Return type: A plain table with CanStart, StartTake, StartHold, NextPart, Advance, NoteRefused, NoteFenced,
	NoteStepFenced, CanSendStep, SendStep, NoteTxStepHeard, TakeClosedTxStep, IsReadingPart and BeginAfterRead.
	Example usage:
		if Walk.CanStart(State, Call, Clock) then Walk.StartTake(State, Call, Arrived, Clock, Commands) end
--]=]

local Composed = require("../../Composed")
local Events = require("../../Events")
local Fates = require("../../Stored/Items/Fates")
local Fence = require("./Fence")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../Shapes")
local HotState = require("../State")
local InFlight = require("../../Reading/InFlight")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Reasons = require("../../Constants/Reasons")
local Replies = require("../../Replies")
local StepAnswer = require("../../Tx/Call/StepAnswer")
local Steps = require("./Steps")
local View = require("./View")

type Command = Events.Command
type OpName = Names.OpName
type HoldCall = HotShapes.HoldCall
type WalkCall = HotShapes.WalkCall
type TakeCall = HotShapes.TakeCall
type Reason = Reasons.Reason
type State = Composed.State
type PartReason = Fates.PartReason
type PartTry = HotState.PartTry
type QuantityView = HotState.QuantityView
type Walk = HotState.Walk

type Plan = { read Kind: "Answers", read Reason: Reason } | { read Kind: "Sends", read Order: { number } }

local ProbeMax = Hot.ProbeMax

local FirstStep = 1
local FencedTry: PartTry = "Fenced"

local SoldOutPlan: Plan = table.freeze({ Kind = "Answers" :: "Answers", Reason = Reasons.SoldOut })
local BusyPlan: Plan = table.freeze({ Kind = "Answers" :: "Answers", Reason = Reasons.Busy })

local function ViewOfCall(State: State, Call: WalkCall): QuantityView
	return HotState.ViewOf(State.Hot, Call.Store, Call.Scope, Call.Quantity)
end

local function DrawnPlan(State: State, Call: WalkCall, Clock: number): Plan
	local Server = State.Server
	local Known = ViewOfCall(State, Call)
	local Parts = Call.Quantity.Parts
	if View.IsSoldOut(Known, Parts) then
		return SoldOutPlan
	end
	if View.IsBusy(Known, Parts, Call.Count, Clock) then
		return BusyPlan
	end
	local ServerNumber = Numbers.ServerNumberOf(Server)
	local Order = View.DrawnOrder(Server.Encoding, Call.Quantity, ServerNumber, Known, Call.Count, Clock)
	return { Kind = "Sends", Order = Order }
end

local function PlanOf(State: State, Call: WalkCall, Clock: number): Plan
	if Call.Method == "Take" then
		local Given = Call.Name
		if Given ~= nil then
			return { Kind = "Sends", Order = View.GameOrder(State.Server.Encoding, Given.Text, Call.Quantity.Parts) }
		end
	end
	return DrawnPlan(State, Call, Clock)
end

local function SendStep(State: State, Walk: Walk, JoinedAt: number, Clock: number, Commands: { Command }): boolean
	local Call = Walk.Call
	if Call.Method == "Take" and Steps.HasLegs(Call) then
		Walk.TxStepId = Steps.SendTxStep(State, Walk, Call, JoinedAt, Clock, Commands)
		Walk.HeardAt = nil
		return true
	end
	return Steps.SendOpStep(State, Walk, JoinedAt, Clock, Commands)
end

local function NoteTxStepHeard(Walk: Walk, Clock: number)
	Walk.HeardAt = Clock
end

local function TakeClosedTxStep(State: State, Walk: Walk): boolean
	local StepId = Walk.TxStepId
	if StepId == nil or Walk.HeardAt == nil or StepAnswer.IsOpen(State, StepId) then
		return false
	end
	Walk.TxStepId = nil
	Walk.HeardAt = nil
	return true
end

local function RefusedTries(Walk: Walk): number
	local Count = 0
	for _, Tried in Walk.Tries do
		if Tried ~= FencedTry then
			Count += 1
		end
	end
	return Count
end

local function IsGameNamed(Call: WalkCall): boolean
	return Call.Method == "Take" and Call.Name ~= nil
end

local function IsFencedAt(Walk: Walk, Known: QuantityView, Position: number, Clock: number): boolean
	return Walk.Name.Kind == "Game" and View.IsPassed(Known, Walk.Order[Position], Walk.Call.Count, Clock)
end

local function NextPart(Walk: Walk, Known: QuantityView, Clock: number): (number?, boolean)
	local Position = Walk.Step + 1
	if Walk.Name.Kind == "Game" then
		if Position > #Walk.Order then
			return nil, false
		end
		return Position, IsFencedAt(Walk, Known, Position, Clock)
	end
	if RefusedTries(Walk) >= ProbeMax then
		return nil, false
	end
	for Next = Position, #Walk.Order do
		if not View.IsPassed(Known, Walk.Order[Next], Walk.Call.Count, Clock) then
			return Next, false
		end
	end
	return nil, false
end

local function Advance(Walk: Walk, Position: number)
	Walk.Step = Position
	Walk.Fence = nil
end

local function NoteRefused(Walk: Walk, Reason: PartReason)
	Walk.Tries[HotState.CurrentPart(Walk)] = Reason
end

local function NoteFenced(Walk: Walk)
	Walk.Tries[HotState.CurrentPart(Walk)] = FencedTry
end

local function NoteStepFenced(Walk: Walk)
	Walk.HasFencedStep = true
end

local function CanSendStep(State: State, Walk: Walk, Position: number): boolean
	local Call = Walk.Call
	if Call.Method == "Take" and Steps.HasLegs(Call) then
		return true
	end
	return InFlight.CanWrite(State.Server, HotState.PartKeyOf(Walk.Call, Walk.Order[Position]))
end

local function Begin(State: State, Walking: Walk, Arrived: number, Clock: number, Commands: { Command }): boolean
	if IsFencedAt(Walking, ViewOfCall(State, Walking.Call), FirstStep, Clock) then
		Fence.SendFence(State, Walking, Clock, Commands)
		return true
	end
	return SendStep(State, Walking, Arrived, Clock, Commands)
end

local function MustReadFirst(State: State, Call: WalkCall, First: number): boolean
	return Call.Method == "Take" and Steps.HasLegs(Call) and not View.IsPresent(ViewOfCall(State, Call), First)
end

local function Launch(
	State: State,
	Call: WalkCall,
	Name: OpName,
	Stamp: number,
	Order: { number },
	Arrived: number,
	Clock: number,
	Commands: { Command }
): boolean
	local Walk: Walk = {
		Call = Call,
		Name = Name,
		Stamp = Stamp,
		Order = Order,
		Step = FirstStep,
		Tries = {},
		HasFencedStep = false,
		Fence = nil,
		TxStepId = nil,
		HeardAt = nil,
		Tidies = {},
		ReadingSince = nil,
	}
	State.Hot.Walks[Call.CallId] = Walk
	HotState.AddStepOwner(State.Hot, Call.CallId, { Kind = "Walk" })
	if Name.Kind == "Drawn" then
		Fence.ReadLackingParts(State, Call, Clock, Commands)
	end
	if MustReadFirst(State, Call, Order[FirstStep]) then
		Walk.ReadingSince = Clock
		Fence.ReadPart(State, Call, Order[FirstStep], Clock, Commands)
		return false
	end
	return Begin(State, Walk, Arrived, Clock, Commands)
end

local function IsReadingPart(Walking: Walk, Store: string, Scope: string, Name: string, Index: number): boolean
	local Call = Walking.Call
	return Walking.ReadingSince ~= nil
		and Call.Store == Store
		and Call.Scope == Scope
		and Call.Quantity.Name == Name
		and Walking.Order[FirstStep] == Index
end

local function BeginAfterRead(State: State, Walking: Walk, Clock: number, Commands: { Command })
	Walking.ReadingSince = nil
	local Call = Walking.Call
	if Begin(State, Walking, Clock, Clock, Commands) and Call.Method == "Take" then
		Steps.RememberGivenName(State.Server, Call, Walking.Order[FirstStep], Commands)
	end
end

local function CanStart(State: State, Call: WalkCall, Clock: number): boolean
	if State.Server.ServerNumber == nil then
		return false
	end
	local Plan = PlanOf(State, Call, Clock)
	if Plan.Kind == "Answers" then
		return true
	end
	if Call.Method == "Take" and Steps.HasLegs(Call) then
		return true
	end
	local First = Plan.Order[FirstStep]
	if IsGameNamed(Call) and View.IsPassed(ViewOfCall(State, Call), First, Call.Count, Clock) then
		return true
	end
	return InFlight.CanWrite(State.Server, HotState.PartKeyOf(Call, First))
end

local function StartTake(State: State, Call: TakeCall, Arrived: number, Clock: number, Commands: { Command })
	local Plan = PlanOf(State, Call, Clock)
	if Plan.Kind == "Answers" then
		return Replies.ReplyFailed(Commands, Call.CallId, Plan.Reason)
	end
	local FirstPart = Plan.Order[FirstStep]
	if Steps.HasLegs(Call) and View.IsAbsentNow(ViewOfCall(State, Call), FirstPart, Clock) then
		return Replies.ReplyFailed(Commands, Call.CallId, Reasons.Missing)
	end
	local Name, Stamp = Steps.NameAndStampOf(State.Server, Call, FirstPart, Clock)
	if Launch(State, Call, Name, Stamp, Plan.Order, Arrived, Clock, Commands) then
		Steps.RememberGivenName(State.Server, Call, FirstPart, Commands)
	end
end

local function StartHold(State: State, Call: HoldCall, Arrived: number, Clock: number, Commands: { Command })
	local Plan = PlanOf(State, Call, Clock)
	if Plan.Kind == "Answers" then
		return Replies.ReplyFailed(Commands, Call.CallId, Plan.Reason)
	end
	Launch(State, Call, Numbers.DrawnName(State.Server), Clock, Plan.Order, Arrived, Clock, Commands)
end

return {
	CanStart = CanStart,
	StartTake = StartTake,
	StartHold = StartHold,
	NextPart = NextPart,
	Advance = Advance,
	NoteRefused = NoteRefused,
	NoteFenced = NoteFenced,
	NoteStepFenced = NoteStepFenced,
	CanSendStep = CanSendStep,
	SendStep = SendStep,
	NoteTxStepHeard = NoteTxStepHeard,
	TakeClosedTxStep = TakeClosedTxStep,
	IsReadingPart = IsReadingPart,
	BeginAfterRead = BeginAfterRead,
}
