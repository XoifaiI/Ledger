--!strict
--!optimize 2

--[=[
	Rule: The parts that one record transform is built from.

	A rule has a check, a change and a test that must hold after the write. Each part is optional.
	A rule that refuses with no reason is quiet. The caller asked, and the answer is no,
	which is not a failure.

	A pass is made once and cleared before each run, because a datastore may run one transform more
	than one time. New and Reset are next to each other so a part added to a pass is cleared as well.

	Return type: A table with New, Reset and Quiet.
	Example usage:
		local Rule = require("./Rule")
		Rule.Quiet(Pass)
--]=]

local Contract = require("../Contract/Op")
local Reasons = require("../Contract/Reason")

type Record = Contract.Record<any>
type Reason = Reasons.Reason

export type Pass = {
	Refused: Reason?,
	Silent: boolean,
	Notes: { [string]: any },
}

export type Rule = {
	Name: string,
	Check: ((Record: Record, Pass: Pass) -> Reason?)?,
	Apply: ((Record: Record, Pass: Pass) -> Record?)?,
	After: ((Before: Record, After: Record, Pass: Pass) -> string?)?,
}

local function Quiet(Pass: Pass)
	Pass.Silent = true
end

local function New(): Pass
	return { Refused = nil, Silent = false, Notes = {} }
end

local function Reset(Pass: Pass)
	Pass.Refused = nil
	Pass.Silent = false
	table.clear(Pass.Notes)
end

return table.freeze({
	New = New,
	Reset = Reset,
	Quiet = Quiet,
})
