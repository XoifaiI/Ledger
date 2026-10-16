--!strict
--!optimize 2

--[=[
	StepAnswer: what a step Tx call (BeginStep) hands its quantity call: its answer, or why it never began, its name
	then, the decider's value and refusing fate, and its refused legs' keys. Taking it clears it and ends a finished
	call; a Followed step hands on its next definite answer too. AbandonAtClose drops every Tx call not committing.

	Return type: A plain table with Take, Follow, IsOpen, IsDeliverable and AbandonAtClose, and the StepAnswer type.
	Example usage:
		local Answer = StepAnswer.Take(State, CallId)
--]=]

local Composed = require("../../Composed")
local Events = require("../../Events")
local Fates = require("../../Stored/Items/Fates")
local Names = require("../../Encoding/Names")
local Replies = require("../../Replies")
local Sorted = require("../../Sorted")
local TentReports = require("./TentReports")
local TxState = require("../State")

type Fate = Fates.Fate
type GivenName = Names.GivenName
type State = Composed.State

export type StepAnswer = {
	read Given: Events.Answer,
	read Name: GivenName?,
	read DeciderValue: number?,
	read DeciderFate: Fate?,
	read Refused: { [string]: boolean },
}

local function RefusedLegs(Call: TxState.Call): { [string]: boolean }
	local Refused: { [string]: boolean } = {}
	for _, Key in Call.OtherKeys do
		local Text = Names.KeyText(Key)
		local Report = Call.TentReports[Text]
		if Report ~= nil and TentReports.RefusalFate(Report) ~= nil then
			Refused[Text] = true
		end
	end
	return Refused
end

local function Take(State: State, CallId: number): StepAnswer?
	local Failure = State.Tx.StepFailures[CallId]
	if Failure ~= nil then
		State.Tx.StepFailures[CallId] = nil
		local Failed: Events.Answer = { Kind = "Failed", Reason = Failure, State = nil }
		return { Given = Failed, Name = nil, DeciderValue = nil, DeciderFate = nil, Refused = {} }
	end
	local Call = State.Tx.Calls[CallId]
	if Call == nil or Call.Given == nil then
		return nil
	end
	local Resolving = Call.Resolving
	local Taken: StepAnswer = {
		Given = Call.Given,
		Name = Replies.GivenNameOf(Call.Name, Call.Stamp),
		DeciderValue = if Resolving ~= nil then Resolving.DeciderValue else nil,
		DeciderFate = Call.DeciderFate,
		Refused = RefusedLegs(Call),
	}
	Call.Given = nil
	if Call.Phase == "Done" then
		TxState.EndCall(State.Tx, Call)
	end
	return Taken
end

local function Follow(State: State, CallId: number)
	local Call = State.Tx.Calls[CallId]
	if Call ~= nil then
		Call.OwesOutcome = true
	end
end

local function IsOpen(State: State, CallId: number): boolean
	return State.Tx.Calls[CallId] ~= nil or State.Tx.PendingCalls[CallId] ~= nil
end

local function IsDeliverable(State: State, CallId: number): boolean
	if State.Tx.StepFailures[CallId] ~= nil or not IsOpen(State, CallId) then
		return true
	end
	return State.Tx.Calls[CallId] ~= nil and State.Tx.Calls[CallId].Given ~= nil
end

local function AbandonAtClose(State: State)
	State.Tx.PendingCalls = {}
	State.Tx.StepFailures = {}
	for _, CallId in Sorted.SortedIds(State.Tx.Calls) do
		local Resolving = State.Tx.Calls[CallId].Resolving
		if Resolving == nil or Resolving.Outcome ~= "Commit" then
			State.Tx.Calls[CallId] = nil
		end
	end
end

return {
	Take = Take,
	Follow = Follow,
	IsOpen = IsOpen,
	IsDeliverable = IsDeliverable,
	AbandonAtClose = AbandonAtClose,
}
