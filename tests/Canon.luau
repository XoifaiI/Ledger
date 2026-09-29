--!strict

--[=[

	Canon: The cases for Encode/Canon.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Canon = require("../src/Encode/Canon")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

Describe("Canon", function()
	Test("a table prints the same whatever order it was built in", function()
		local Forward: { [string]: number } = {}
		for Index = 1, 50 do
			Forward[`k{Index}`] = Index
		end
		local Backward: { [string]: number } = { gone = 0 }
		for Index = 50, 1, -1 do
			Backward[`k{Index}`] = Index
		end
		Backward.gone = nil
		Expect(Canon(Forward)).toBe(Canon(Backward))

		local Built = {}
		for Index = 1, 5 do
			table.insert(Built, Index * 10)
		end
		Expect(Canon(Built)).toBe(Canon({ 10, 20, 30, 40, 50 }))
		Expect(Canon({ a = { x = 1, y = { 2, 3 } }, b = true })).toBe(Canon({ b = true, a = { y = { 2, 3 }, x = 1 } }))
	end)

	Test("values that differ print differently", function()
		local Pairs: { { any } } = {
			{ 1, "1" },
			{ true, 1 },
			{ false, 0 },
			{ "", buffer.create(0) },
			{ {}, { {} } },
			{ { [1] = "a" }, { ["1"] = "a" } },
			{ { a = "x,b=y" }, { a = "x", b = "y" } },
			{ { "a", "b" }, { "b", "a" } },
			{ { 1, 2 }, { [1] = 1, [3] = 2 } },
			{ "a\0b", "a\0c" },
		}
		for _, Pair in Pairs do
			Expect(Canon(Pair[1])).never.toBe(Canon(Pair[2]))
		end
	end)

	Test("negative zero prints as zero", function()
		Expect(Canon(-0)).toBe(Canon(0))
		Expect(Canon({ x = -0 })).toBe(Canon({ x = 0 }))
	end)

	Test("a value no server can print the same way is refused", function()
		local Cyclic: { [string]: any } = {}
		Cyclic.Self = Cyclic
		local Refused: { { any } } = {
			{ 0 / 0, "Canon: cannot print a number, a nan, or a table nested past 64" },
			{ print, "Canon: cannot print a function, a nan, or a table nested past 64" },
			{ Cyclic, "Canon: cannot print a table, a nan, or a table nested past 64" },
			{ { [true] = 1 }, "Canon: a table key is a boolean" },
		}
		for _, Pair in Refused do
			Expect(function()
				Canon(Pair[1])
			end).toThrow(Pair[2])
		end
		Expect(Canon({ 1 })).toBe(Canon({ 1 }))
	end)
end)

return nil
