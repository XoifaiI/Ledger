--!strict
--!optimize 2

--[=[
	Helper: finishing another cut's gate (cuts sheet 8.4). A key has one helper, which sends the gate's cut op with
	role helper for every waiter, a gated Tx call or a touch, reading an unseen key's incarnation first. A helper has
	no answer to give. A touch leaves a gate to the key's open cut call.

	Return type: A plain table with FinishGate, IsFinishing, HasCutCall and TakeWaiters.
	Example usage:
		Helper.FinishGate(State, Key, Held, { Kind = "Touch", Key = Key }, Clock, Commands)
--]=]

local Call = require("./Call")
local Composed = require("../../Composed")
local CutState = require("../State")
local Events = require("../../Events")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Seal = require("../../Stored/Items/Seal")

type Command = Events.Command
type StoreKey = Names.StoreKey
type Gate = Seal.Gate
type State = Composed.State
type CutCall = CutState.CutCall
type CutsState = CutState.CutsState
type GateWaiter = CutState.GateWaiter

local function HelperOf(State: State, Key: StoreKey, Held: Gate, Clock: number): CutCall
	local CallId = Numbers.NewHelperId(State.Server)
	local Helping = CutState.NewCall(CallId, Key, Held.Kind, Call.GateOpName(Held), Held.Stamp, nil, "Helper", Clock)
	Helping.HasAnswered = true
	return Helping
end

local function AddWaiter(Cuts: CutsState, Text: string, For: GateWaiter)
	local Waiting = Cuts.Waiters[Text]
	if Waiting == nil then
		Waiting = {}
		Cuts.Waiters[Text] = Waiting
	end
	table.insert(Waiting, For)
end

local function FinishGate(
	State: State,
	Key: StoreKey,
	Held: Gate,
	For: GateWaiter,
	Clock: number,
	Commands: { Command }
)
	local Cuts = State.Cuts
	local Text = Names.KeyText(Key)
	AddWaiter(Cuts, Text, For)
	if Cuts.Helpers[Text] ~= nil then
		return
	end
	local Helping = HelperOf(State, Key, Held, Clock)
	Cuts.Helpers[Text] = Helping
	Call.SendFirst(State, Helping, Clock, Commands)
end

local function IsFinishing(Cuts: CutsState, Key: StoreKey): boolean
	return Cuts.Helpers[Names.KeyText(Key)] ~= nil
end

local function HasCutCall(Cuts: CutsState, Key: StoreKey): boolean
	local Text = Names.KeyText(Key)
	for _, Cutting in Cuts.Calls do
		if Names.KeyText(Cutting.Key) == Text then
			return true
		end
	end
	return false
end

local function TakeWaiters(Cuts: CutsState, Key: StoreKey): { GateWaiter }
	local Text = Names.KeyText(Key)
	local Taken = Cuts.Waiters[Text]
	if Taken == nil then
		return {}
	end
	Cuts.Waiters[Text] = nil
	return Taken
end

return {
	FinishGate = FinishGate,
	IsFinishing = IsFinishing,
	HasCutCall = HasCutCall,
	TakeWaiters = TakeWaiters,
}
