--!strict
--!optimize 2

--[=[
	Delivery: hands a quantity call's writer op and step Tx results to their owner, by kind. A Late StepOut entry, or a
	step Tx's answer after its walk ended, goes to Outcomes; any other entry is its owner's, dropped once the owner left
	with its answered call. At an ended close step Txs' answers go once more.

	Return type: A plain table with DrainStepOut, DeliverTxSteps and AfterEndedClose.
	Example usage:
		if Delivery.DrainStepOut(State, Clock, Commands) then ... end
--]=]

local CloseCalls = require("./Calls/Close")
local Composed = require("../Composed")
local Events = require("../Events")
local Gather = require("./Calls/Gather")
local HotState = require("./State")
local Moves = require("./Calls/Moves")
local Outcomes = require("./Walk/Outcomes")
local Reports = require("./Walk/Reports")
local Shapes = require("../Shapes")
local Sorted = require("../Sorted")
local StepAnswer = require("../Tx/Call/StepAnswer")

type Command = Events.Command
type CloseOwner = HotState.CloseOwner
type StepOwner = HotState.StepOwner
type StepOut = Shapes.StepOut
type State = Composed.State

type StepOutHandler = (State, StepOwner, StepOut, number, { Command }) -> ()

local ModuleName = "Delivery"
local NoWalk = `{ModuleName}: this call is never made. A walk's owner leaves with its walk.`

local function OnWalkOut(State: State, _Owner: StepOwner, Out: StepOut, Clock: number, Commands: { Command })
	local Walking = State.Hot.Walks[Out.CallId]
	if Walking == nil then
		error(NoWalk)
	end
	Reports.OnStepOut(State, Walking, Out, Clock, Commands)
end

local function OnCloseOut(State: State, Owner: CloseOwner, Out: StepOut, Clock: number, Commands: { Command })
	State.Hot.StepOwners[Out.CallId] = nil
	CloseCalls.OnCloseOut(State, Owner.CallId, Out, Clock, Commands)
end

local StepOutHandlers = {
	Walk = OnWalkOut,
	Close = OnCloseOut,
	Confirm = Moves.OnConfirmOut,
	Release = Moves.OnReleaseOut,
}

local function DeliverStepOut(State: State, Out: StepOut, Clock: number, Commands: { Command })
	if Out.Kind == "Late" then
		return Outcomes.OnLateStep(State, Out.CallId, Out.Reason, Out.Report, Commands)
	end
	local Owner = State.Hot.StepOwners[Out.CallId]
	if Owner == nil then
		return
	end
	local Handler = (StepOutHandlers :: { [string]: StepOutHandler })[Owner.Kind]
	Handler(State, Owner, Out, Clock, Commands)
end

local function DrainStepOut(State: State, Clock: number, Commands: { Command }): boolean
	local Server = State.Server
	local HasOwnerEntry = false
	while #Server.StepOut > 0 do
		local Pending = Server.StepOut
		Server.StepOut = {}
		for _, Out in Pending do
			DeliverStepOut(State, Out, Clock, Commands)
			if Out.Kind ~= "Late" then
				HasOwnerEntry = true
			end
		end
	end
	return HasOwnerEntry
end

local function DeliverTxStep(State: State, CallId: number, Clock: number, Commands: { Command }): StepAnswer.StepAnswer?
	local Step = State.Hot.TxSteps[CallId]
	local Taken = StepAnswer.Take(State, CallId)
	if Taken ~= nil then
		State.Hot.TxSteps[CallId] = nil
		if Step.Kind == "Walk" then
			local Walking = State.Hot.Walks[Step.CallId]
			if Walking ~= nil then
				Reports.OnTxStep(State, Walking, Taken, Clock, Commands)
			else
				Outcomes.OnLateTxStep(State, Step.CallId, Taken, Commands)
			end
		elseif Step.Kind == "Confirm" then
			Moves.OnConfirmTx(CallId, Step, Taken, Commands)
		elseif Step.Kind == "Gather" then
			Gather.OnTxStep(State, CallId, Step, Taken, Commands)
		end
	elseif not StepAnswer.IsOpen(State, CallId) then
		State.Hot.TxSteps[CallId] = nil
		if Step.Kind == "Walk" and State.Hot.Walks[Step.CallId] == nil then
			Outcomes.OnLateTxStep(State, Step.CallId, nil, Commands)
		end
	end
	return Taken
end

local function DeliverTxSteps(State: State, Clock: number, Commands: { Command }): boolean
	local IsDelivered = false
	local function IsDeliverable(CallId: number): boolean
		return StepAnswer.IsDeliverable(State, CallId)
	end
	for _, CallId in Sorted.SortedDueIds(State.Hot.TxSteps, IsDeliverable) do
		if DeliverTxStep(State, CallId, Clock, Commands) ~= nil then
			IsDelivered = true
		end
	end
	return IsDelivered
end

local function AfterEndedClose(State: State, Clock: number, Commands: { Command })
	DeliverTxSteps(State, Clock, Commands)
end

return {
	DrainStepOut = DrainStepOut,
	DeliverTxSteps = DeliverTxSteps,
	AfterEndedClose = AfterEndedClose,
}
