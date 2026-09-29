--!strict

--[=[

	Numbers: The cases for Server/Numbers, stepped by hand with the replies a datastore gives.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Effect = require("../src/Server/Effect")
local Limits = require("../src/Core/Constants/Limits")
local Machine = require("../src/Core/Machine")
local Numbers = require("../src/Server/Numbers")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local function Seconds(Sent: Effect.Effect): number?
	return if Sent.Kind == Effect.Kind.Wait then Sent.Seconds else nil
end

Describe("Numbers", function()
	Test("a take that does not land waits longer each time, and a landed one answers the count its write made", function()
		local Context = Numbers.Context(nil :: any, "job")
		local Call, Effects, First = Machine.Start(Numbers.Take, Context)
		local Waits: { number? } = {}
		for Try = 1, 7 do
			Expect(Effects[1].Kind).toBe(Effect.Kind.Update)
			if Try == 4 then
				Effects, First = Machine.Step(Call, First, true, 41, nil, false)
			else
				Effects, First = Machine.Step(Call, First, false, "502: busy")
			end
			table.insert(Waits, Seconds(Effects[1]))
			Effects, First = Machine.Step(Call, First, true)
		end
		Expect(table.concat(Waits :: { any }, " ")).toBe("1 2 4 8 16 30 30")
		Machine.Step(Call, First, true, 5, nil, true)
		Expect(Machine.IsFinal(Call)).toBe(true)
		Expect(Call.Answer).toBe(5 * Limits.COUNTERS + Context.Index)
	end)

	Test("a counter counts up from nothing and never over a value that is not a count", function()
		Expect(Numbers.Bump(nil)).toBe(1)
		Expect(Numbers.Bump(41)).toBe(42)
		Expect(Numbers.Bump("41")).toBeNil()
		Expect(Numbers.Bump(1.5)).toBeNil()
	end)
end)

return nil
