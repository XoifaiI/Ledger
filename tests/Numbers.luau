--!strict

--[=[

	Numbers: The cases for Server/Numbers, stepped by hand and run through Server/Driver.

	Counter is a datastore that holds values in a table and runs each transform once.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local DataStore = require("../src/Adapters/DataStore")
local Driver = require("../src/Server/Driver")
local Effect = require("../src/Server/Effect")
local Limits = require("../src/Core/Constants/Limits")
local Machine = require("../src/Core/Machine")
local Numbers = require("../src/Server/Numbers")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local function Counter(Values: { [string]: unknown }): DataStore.Store
	local Fake = {}
	function Fake.UpdateAsync(_: any, Key: string, Transform: (unknown, any) -> unknown): (unknown, any)
		local Next = Transform(Values[Key], nil)
		if Next ~= nil then
			Values[Key] = Next
		end
		return Next, nil
	end
	return Fake :: any
end

local function Seconds(Sent: Effect.Effect): number?
	return if Sent.Kind == Effect.Kind.Wait then Sent.Seconds else nil
end

Describe("Numbers", function()
	Test("a failed take waits, doubling up to the cap, and a landed one answers the count its write made", function()
		local Context = Numbers.Context(Counter({}), "job")
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

	Test("two servers on one counter key take different numbers", function()
		local Store = Counter({})
		local First = Driver.Run(Numbers.Take, Numbers.Context(Store, "job")):Wait()
		local Second = Driver.Run(Numbers.Take, Numbers.Context(Store, "job")):Wait()
		Expect(First).never.toBe(Second)
		Expect((First :: number) % Limits.COUNTERS).toBe((Second :: number) % Limits.COUNTERS)
	end)

	Test("a counter counts up from nothing and never over a value that is not a count", function()
		Expect(Numbers.Bump(nil)).toBe(1)
		Expect(Numbers.Bump(41)).toBe(42)
		Expect(Numbers.Bump("41")).toBeNil()
		Expect(Numbers.Bump(1.5)).toBeNil()
	end)
end)

return nil
