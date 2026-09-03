--!strict
--!optimize 2

--[=[

	Transform: Runs a list of rules against one key.

	Each rule checks, then changes, then answers whether it still holds once the write landed. A
	datastore can run one transform more than once. Every run clears the pass first, so nothing a rule
	wrote survives into the next.

	Return type: A table with Run, which gives back the record before, the record after, and the reason.
	Example usage:
		local Transform = require("./Transform")
		local Outcome = Transform.Run(Update, Key, List)
--]=]

local Shapes = require("../Core/Shapes")
local Reasons = require("../Core/Constants/Reasons")
local Rules = require("./Rules")

type Record = Shapes.Record<any>
type Reason = Reasons.Reason
type Pass = Rules.Pass
type Rule = Rules.Rule

export type Outcome = {
	Before: Record,
	After: Record,
	Changed: boolean,
	Refused: Reason?,
	Notes: { [string]: any },
}

export type Update = (Key: string, Apply: (Record) -> Record?) -> { Before: Record, After: Record, Changed: boolean }

local function Run(Update: Update, Key: string, List: { Rule }): Outcome
	local Pass: Pass = Rules.New()

	local Result = Update(Key, function(Record: Record): Record?
		Rules.Reset(Pass)

		local Next: Record = Record
		for _, Held in List do
			local Check = Held.Check
			if Check ~= nil then
				local Why = Check(Next, Pass)
				if Why ~= nil then
					Pass.Refused = Why
					return nil
				end
				if Pass.Silent then
					return nil
				end
			end

			local Apply = Held.Apply
			if Apply ~= nil then
				local Changed = Apply(Next, Pass)
				if Changed == nil then
					return nil
				end
				Next = Changed
			end
		end

		return Next
	end)

	if Result.Changed then
		for _, Held in List do
			local After = Held.After
			if After == nil then
				continue
			end
			local Broke = After(Result.Before, Result.After, Pass)
			assert(Broke == nil, `the '{Held.Name}' rule on '{Key}' did not hold after the write: {tostring(Broke)}`)
		end
	end

	return {
		Before = Result.Before,
		After = Result.After,
		Changed = Result.Changed,
		Refused = Pass.Refused,
		Notes = Pass.Notes,
	}
end

return table.freeze({
	Run = Run,
})
