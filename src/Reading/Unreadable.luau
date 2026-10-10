--!strict
--!optimize 2

--[=[
	Unreadable: what a key this build cannot read answers (Answers.md 4). A newer Ledger's value answers Behind; a value
	no Ledger build wrote, one this build's migrations fail on, or a balance its arithmetic rejects answers Unreadable,
	warned of once per store. An unreadable amount beside the state (Amounts) is not the key's value: its caller answers
	it.

	Return type: A plain table with ReasonOf, Warn and WarnOfReport, and the Cause type.
	Example usage:
		Replies.ReplyFailed(Commands, CallId, Unreadable.ReasonOf(Cause))
		Unreadable.Warn(State, Key, Cause, Commands)
--]=]

local Cache = require("./Cache")
local Events = require("../Events")
local JudgingShapes = require("../Judging/Shapes")
local Names = require("../Encoding/Names")
local Reasons = require("../Constants/Reasons")
local Shapes = require("../Shapes")

type Command = Events.Command
type Reason = Reasons.Reason
type Report = JudgingShapes.Report
type StoreKey = Names.StoreKey
type ServerState = Shapes.ServerState

export type Cause = "Newer" | "Foreign" | "Migration" | "Balance"

local Warnings: { [Cause]: string } = {
	Foreign = "holds a value no Ledger build wrote. Its calls answer Unreadable until the game repairs the value.",
	Migration = "holds a value this build's migrations fail on. Its reads answer Unreadable until a fixed build runs.",
	Balance = "holds a balance this build's arithmetic rejects. Its calls answer Unreadable until it is repaired.",
}

local function ReasonOf(Cause: Cause): Reason
	if Cause == "Newer" then
		return Reasons.Behind
	end
	return Reasons.Unreadable
end

local function Warn(State: ServerState, Key: StoreKey, Cause: Cause, Commands: { Command })
	local Store = Cache.StoreOf(State, Key)
	if Cause == "Newer" or Store.IsUnreadableWarned == true then
		return
	end
	Store.IsUnreadableWarned = true
	local Warning: Command = { Kind = "Warn", Key = Key, Text = Warnings[Cause] }
	table.insert(Commands, Warning)
end

local function WarnOfReport(State: ServerState, Key: StoreKey, Report: Report?, Commands: { Command })
	if Report == nil or Report.Kind ~= "Unreadable" or Report.Cause == "Amounts" then
		return
	end
	Warn(State, Key, Report.Cause, Commands)
end

return {
	ReasonOf = ReasonOf,
	Warn = Warn,
	WarnOfReport = WarnOfReport,
}
