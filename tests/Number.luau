--!strict

--[=[

	Number: The cases for Calls/Number, stepped directly with the replies it hears.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Heard = require("./Heard")
local Limits = require("../src/Core/Constants/Limits")
local Machine = require("../src/Machine/Machine")
local Number = require("../src/Calls/Number")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

Describe("Number", function()
	Test("a count that fails rests longer each time, and one that lands answers the number its count gives", function()
		local Context = Number.Context("job")
		local Call, Asked = Machine.Start(Number.Machine, Context, Heard.NOW)
		local Waits: { number } = {}
		for _ = 1, 6 do
			Expect(Asked[1].Ask.Kind).toBe("Count")
			Asked = Machine.Step(Call, Asked[1].Id, Heard.Failed(true))
			local Ask = Asked[1].Ask
			table.insert(Waits, if Ask.Kind == "Wait" then Ask.Seconds else -1)
			Asked = Machine.Step(Call, Asked[1].Id, Heard.Done())
		end
		Expect(table.concat(Waits, " ")).toBe("1 2 4 8 16 30")
		Machine.Step(Call, Asked[1].Id, Heard.Read(5))
		Expect(Machine.AnswerOf(Call)).toBe(5 * Limits.COUNTERS + Context.Index)
		Expect(Machine.IsFinal(Call)).toBe(true)
	end)
end)

return nil
