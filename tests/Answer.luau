--!strict

--[=[

	Answer: The cases for Core/Answer.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Answer = require("../src/Core/Answer")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

Describe("Answer", function()
	Test("each answer is its own name and the table cannot change", function()
		local Count = 0
		for Name, Value in Answer :: any do
			Expect(Value).toBe(Name)
			Count += 1
		end
		Expect(Count).toBe(15)
		Expect(table.isfrozen(Answer)).toBe(true)
	end)
end)

return nil
