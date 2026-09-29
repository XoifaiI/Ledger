--!strict

--[=[

	Errors: The cases for Core/Errors.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Errors = require("../src/Core/Errors")

local Describe, Test, Expect, Similar, Heard = Testing.Describe, Testing.Test, Testing.Expect, Testing.Similar, Testing.Heard

local function Api(Legs: number)
	if Legs < 2 then
		Errors.Misuse("a transaction needs at least two legs")
	end
end

Describe("Errors", function()
	Test("misuse throws at the game's own call", function()
		Expect(function()
			Api(1)
		end).toThrow("Ledger: a transaction needs at least two legs")
		local _, Message = pcall(function()
			Api(1)
		end)
		Expect((string.find(tostring(Message), "tests", 1, true))).never.toBeNil()
		Expect((string.find(tostring(Message), "src", 1, true))).toBeNil()
	end)

	Test("a bug is warned with the prefix a test watches for", function()
		Heard()
		Errors.Bug("a future settled twice")
		Expect(Heard()).toBe(Similar({ "Ledger bug: a future settled twice. please report this" }))
	end)
end)

return nil
