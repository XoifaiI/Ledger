--!strict
--!optimize 2

--[=[
	Rule: The parts that one record transform is built from.
	
	A rule has a check, a change and a test that must hold after the write. Each part is optional.
	A rule that refuses with no reason is quiet. The caller asked, and the answer is no,
	which is not a failure.
	
	Return type: A table with New, Quiet and Refuse.
	Example usage:
		local Rule = require("./Rule")
		Rule.Refuse(Pass, Reasons.Busy)
--]=]

local Contract = require("../Contract/Op")
local Reasons = require("../Contract/Reason")

type Record = Contract.Record<any>
type Reason = Reasons.Reason

export type Pass = {
	Refused: Reason?,
	Silent: boolean,
	Notes: { [string]: any }
}

export type Rule = {
	Name: string,
	Check: ((Record: Record, Pass: Pass) -> Reason?)?,
	Apply: ((Record: Record, Pass: Pass) -> Record?)?,
	After: ((Before: Record, After: Record, Pass: Pass) -> string?)?
}

local function Quiet(Pass: Pass)
	Pass.Silent = true
end

local function Refuse(Pass: Pass, Why: Reason)
	Pass.Refused = Why
end

local function New(Name: string): Pass
	return { Refused = nil, Silent = false, Notes = {} }
end

return table.freeze({
	New = New,
	Quiet = Quiet,
	Refuse = Refuse
})
