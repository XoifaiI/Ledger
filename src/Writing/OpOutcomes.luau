--!strict
--!optimize 2

--[=[
	OpOutcomes: the outcome a writer op's call is owed once it answered Unresolved and the op stays queued (ruling A1).
	It settles once: with the answer the op is later heard with, by the first answer's rules, or Unresolved when the op
	leaves unheard, shed Busy or ended by the close. A step op's settling goes to StepOut as Late.

	Return type: A plain table with Owes, HearLate, SettleOnLeaving and Stop.
	Example usage:
		Op.OwesOutcome = OpOutcomes.Owes(Op, Reason)
--]=]

local Events = require("../Events")
local JudgingShapes = require("../Judging/Shapes")
local Names = require("../Encoding/Names")
local Reasons = require("../Constants/Reasons")
local Replies = require("../Replies")
local Shapes = require("../Shapes")

type Answer = Events.Answer
type Command = Events.Command
type StoreKey = Names.StoreKey
type Reason = Reasons.Reason
type Report = JudgingShapes.Report
type Op = Shapes.Op
type ServerState = Shapes.ServerState
type StepOut = Shapes.StepOut

type Caller = { read CallId: number?, read IsStep: boolean }

local UndecidedReport: Report = table.freeze({ Kind = "Undecided" :: "Undecided" })

local function Owes(Op: Op, Reason: Reason): boolean
	return Reason == Reasons.Unresolved and Op.CallId ~= nil
end

local function HearLate(State: ServerState, Commands: { Command }, Key: StoreKey, Op: Op, Heard: Answer, Report: Report)
	local CallId = Op.CallId
	if CallId == nil then
		return
	end
	if Op.IsStep then
		local Reason = if Heard.Kind == "Failed" then Heard.Reason else nil
		local Late: StepOut = { Kind = "Late", CallId = CallId, Reason = Reason, Report = Report }
		table.insert(State.StepOut, Late)
		return
	end
	if Op.OwesOutcome then
		Op.OwesOutcome = false
		Replies.SettleOutcome(Commands, Key, CallId, Heard)
	end
end

local function SettleOnLeaving(Commands: { Command }, Key: StoreKey, Leaving: Caller, Reason: Reason?)
	local CallId = Leaving.CallId
	if Reason == Reasons.Unresolved and CallId ~= nil and not Leaving.IsStep then
		Replies.SettleOutcomeUnresolved(Commands, Key, CallId)
	end
end

local function Stop(State: ServerState, Commands: { Command }, Key: StoreKey, Op: Op)
	local CallId = Op.CallId
	if not Op.OwesOutcome or CallId == nil then
		return
	end
	Op.OwesOutcome = false
	if Op.IsStep then
		local Late: StepOut = { Kind = "Late", CallId = CallId, Reason = Reasons.Unresolved, Report = UndecidedReport }
		table.insert(State.StepOut, Late)
		return
	end
	Replies.SettleOutcomeUnresolved(Commands, Key, CallId)
end

return {
	Owes = Owes,
	HearLate = HearLate,
	SettleOnLeaving = SettleOnLeaving,
	Stop = Stop,
}
