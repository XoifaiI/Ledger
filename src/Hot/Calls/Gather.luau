--!strict
--!optimize 2

--[=[
	Gather: an open-mode Take with gather set (sheet H8). Part debit legs are sized from the view, most free first, in
	as many parts as the receiver's pinned record fits in MarkMax. A view that cannot fill it reads the parts it lacks
	(Busy), else answers Short (Chosen 7 scenario 5), held when those parts' units cover the count.

	Return type: A plain table with CanStart, StartGather and OnTxStep.
	Example usage:
		Gather.StartGather(State, Call, Clock, Clock, Commands)
--]=]

local Composed = require("../../Composed")
local Events = require("../../Events")
local Fates = require("../../Stored/Items/Fates")
local Fence = require("../Walk/Fence")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../Shapes")
local HotState = require("../State")
local KindSetup = require("../../Judging/KindSetup")
local Measure = require("../../Tx/Call/Measure")
local Names = require("../../Encoding/Names")
local PartBuild = require("../Part/Build")
local Reasons = require("../../Constants/Reasons")
local Record = require("../../Constants/Record")
local Replies = require("../../Replies")
local Reports = require("../Walk/Reports")
local Sorted = require("../../Sorted")
local StepAnswer = require("../../Tx/Call/StepAnswer")
local TxCalls = require("../../Tx/Call/Call")
local TxShapes = require("../../Tx/Shapes")
local View = require("../Walk/View")

type Answer = Events.Answer
type Command = Events.Command
type TxCall = Events.TxCall
type PartReason = Fates.PartReason
type GatherCall = HotShapes.GatherCall
type TxLeg = TxShapes.TxLeg
type GatherStep = HotState.GatherStep
type QuantityView = HotState.QuantityView
type State = Composed.State

type FreeAt = {
	Index: number,
	Free: number,
}

type Units = {
	Index: number,
	Free: number,
	Held: number,
}

type Sized = {
	Index: number,
	Amount: number,
}

local PartReasons = Fates.PartReason

local function CanStart(State: State): boolean
	return State.Server.ServerNumber ~= nil
end

local function DebitLegs(Call: GatherCall, Indexes: { number }, Count: number): { TxLeg }
	local Legs: { TxLeg } = {}
	for Place = 1, Count do
		table.insert(Legs, PartBuild.DebitLeg(Call, Indexes[Place], Hot.FreeField, Call.Count))
	end
	return Legs
end

local function IsWithinMarkMax(State: State, Call: GatherCall, Indexes: { number }, Count: number): boolean
	local Legs = DebitLegs(Call, Indexes, Count)
	table.insert(Legs, Call.Receiver)
	local ReceiverSetup = KindSetup.SetupOfKey(State.Server, Call.Receiver.Key)
	local Bytes = Measure.PinnedRecordBytes(Legs, #Legs, ReceiverSetup, Measure.MeasuredName(Call.Name))
	return Bytes <= Record.MarkMax
end

local function PartLegsThatFit(State: State, Call: GatherCall, Indexes: { number }): number
	local Most = math.min(#Indexes, Call.PartLegsMost)
	while Most > 0 and not IsWithinMarkMax(State, Call, Indexes, Most) do
		Most -= 1
	end
	return Most
end

local function SizedFromView(State: State, Known: QuantityView, Call: GatherCall): ({ Sized }, number)
	local Candidates: { FreeAt } = {}
	for Index = 0, Call.Quantity.Parts - 1 do
		local Entry = Known.Parts[Index]
		if Entry ~= nil and Entry.Free > 0 then
			table.insert(Candidates, { Index = Index, Free = Entry.Free })
		end
	end
	table.sort(Candidates, function(Left: FreeAt, Right: FreeAt): boolean
		if Left.Free ~= Right.Free then
			return Left.Free > Right.Free
		end
		return Left.Index < Right.Index
	end)
	local Indexes: { number } = {}
	for _, Candidate in Candidates do
		table.insert(Indexes, Candidate.Index)
	end
	local Most = PartLegsThatFit(State, Call, Indexes)
	local Legs: { Sized } = {}
	local Remaining = Call.Count
	for _, Candidate in Candidates do
		if Remaining == 0 or #Legs >= Most then
			break
		end
		local Amount = math.min(Candidate.Free, Remaining)
		table.insert(Legs, { Index = Candidate.Index, Amount = Amount })
		Remaining -= Amount
	end
	return Legs, Remaining
end

local function GatherTx(Call: GatherCall, Legs: { TxLeg }): TxCall
	local Name = Call.Name
	if Name == nil then
		return PartBuild.RuledTxOf(Call.CallId, Legs)
	end
	return PartBuild.NamedTxOf(Call.CallId, Legs, Name)
end

local function HeldOrFree(Free: number, Held: number, Count: number): PartReason
	if Free + Held >= Count then
		return PartReasons.Held
	end
	return PartReasons.Free
end

local function ViewShortReason(State: State, Known: QuantityView, Call: GatherCall): PartReason
	local Candidates: { Units } = {}
	for Index = 0, Call.Quantity.Parts - 1 do
		local Entry = Known.Parts[Index]
		if Entry ~= nil then
			table.insert(Candidates, { Index = Index, Free = Entry.Free, Held = Entry.Held })
		end
	end
	table.sort(Candidates, function(Left: Units, Right: Units): boolean
		if Left.Free + Left.Held ~= Right.Free + Right.Held then
			return Left.Free + Left.Held > Right.Free + Right.Held
		end
		return Left.Index < Right.Index
	end)
	local Indexes: { number } = {}
	for _, Candidate in Candidates do
		table.insert(Indexes, Candidate.Index)
	end
	local Free, Held = 0, 0
	for Place = 1, PartLegsThatFit(State, Call, Indexes) do
		Free += Candidates[Place].Free
		Held += Candidates[Place].Held
	end
	return HeldOrFree(Free, Held, Call.Count)
end

local function AnswerUnfilled(State: State, Call: GatherCall, Known: QuantityView, Clock: number, Commands: { Command })
	if #View.Lacking(Known, Call.Quantity.Parts) > 0 then
		Fence.ReadLackingParts(State, Call, Clock, Commands)
		return Replies.ReplyFailed(Commands, Call.CallId, Reasons.Busy)
	end
	Replies.Reply(Commands, Call.CallId, Reports.ShortAnswerOf(ViewShortReason(State, Known, Call)))
end

local function StartGather(State: State, Call: GatherCall, Arrived: number, Clock: number, Commands: { Command })
	local Known = HotState.ViewOf(State.Hot, Call.Store, Call.Scope, Call.Quantity)
	local Sized, Remaining = SizedFromView(State, Known, Call)
	if Remaining > 0 then
		return AnswerUnfilled(State, Call, Known, Clock, Commands)
	end
	local Legs: { TxLeg } = {}
	local Amounts: { [number]: number } = {}
	for _, Leg in Sized do
		Amounts[Leg.Index] = Leg.Amount
		table.insert(Legs, PartBuild.DebitLeg(Call, Leg.Index, Hot.FreeField, Leg.Amount))
	end
	table.insert(Legs, Call.Receiver)
	HotState.AddTxStep(State.Hot, Call.CallId, { Kind = "Gather", Call = Call, Amounts = Amounts })
	TxCalls.BeginStep(State, GatherTx(Call, Legs), Arrived, Clock, Commands)
end

local function AnswerOf(State: State, Step: GatherStep, Taken: StepAnswer.StepAnswer): Answer
	local Given = Taken.Given
	if Given.Kind == "Succeeded" or Given.Reason ~= Reasons.Refused then
		return Given
	end
	local Call = Step.Call
	local Known = HotState.ViewOf(State.Hot, Call.Store, Call.Scope, Call.Quantity)
	local IsAnyRefused = false
	local IsAnyHeld = false
	for _, Index in Sorted.SortedIds(Step.Amounts) do
		if not Taken.Refused[Names.KeyText(HotState.PartKeyOf(Call, Index))] then
			continue
		end
		IsAnyRefused = true
		local Free, Held = 0, 0
		local Entry = Known.Parts[Index]
		if Entry ~= nil then
			Free, Held = Entry.Free, Entry.Held
		end
		if HeldOrFree(Free, Held, Step.Amounts[Index]) == PartReasons.Held then
			IsAnyHeld = true
		end
	end
	if not IsAnyRefused then
		return Given
	end
	return Reports.ShortAnswerOf(if IsAnyHeld then PartReasons.Held else PartReasons.Free)
end

local function OnTxStep(
	State: State,
	CallId: number,
	Step: GatherStep,
	Taken: StepAnswer.StepAnswer,
	Commands: { Command }
)
	Replies.Reply(Commands, CallId, Replies.Named(AnswerOf(State, Step, Taken), Taken.Name))
end

return {
	CanStart = CanStart,
	StartGather = StartGather,
	OnTxStep = OnTxStep,
}
