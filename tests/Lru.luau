--!strict

--[=[

	Lru: The cases for Util/Lru.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Lru = require("../src/Util/Lru")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

Describe("Lru", function()
	Test("adding past the limit forgets what was touched longest ago", function()
		local Cache: Lru.Lru<number> = Lru.New(2)
		Cache:Put("a", 1)
		Cache:Put("b", 2)
		Expect(Cache:Get("a")).toBe(1)
		Cache:Put("c", 3)
		Expect(Cache:Get("b")).toBeNil()
		Expect(Cache:Get("a")).toBe(1)
		Expect(Cache:Get("c")).toBe(3)
		Expect(Cache.Count).toBe(2)
	end)

	Test("putting a key that is held replaces its value and touches it", function()
		local Cache: Lru.Lru<number> = Lru.New(2)
		Cache:Put("a", 1)
		Cache:Put("b", 2)
		Cache:Put("a", 10)
		Cache:Put("c", 3)
		Expect(Cache:Get("a")).toBe(10)
		Expect(Cache:Get("b")).toBeNil()
		Expect(Cache.Count).toBe(2)
	end)

	Test("a cache of one keeps the last key put and clear forgets everything", function()
		local Cache: Lru.Lru<string> = Lru.New(1)
		Cache:Put("a", "x")
		Cache:Put("b", "y")
		Expect(Cache:Get("a")).toBeNil()
		Expect(Cache:Get("b")).toBe("y")
		Cache:Clear()
		Expect(Cache:Get("b")).toBeNil()
		Expect(Cache.Count).toBe(0)
		Cache:Put("c", "z")
		Expect(Cache:Get("c")).toBe("z")
	end)

	Test("a thousand random steps agree with a plain list", function()
		local Cache: Lru.Lru<number> = Lru.New(8)
		local Order: { string } = {}
		local Values: { [string]: number } = {}
		local Wrong = 0
		math.randomseed(7)
		for Step = 1, 1000 do
			local Key = `k{math.random(0, 19)}`
			local Held = table.find(Order, Key)
			if math.random(1, 3) == 1 then
				local Got = Cache:Get(Key)
				if Got ~= (if Held then Values[Key] else nil) then
					Wrong += 1
				end
				if Held then
					table.remove(Order, Held)
					table.insert(Order, Key)
				end
			else
				Cache:Put(Key, Step)
				Values[Key] = Step
				if Held then
					table.remove(Order, Held)
				elseif #Order == 8 then
					table.remove(Order, 1)
				end
				table.insert(Order, Key)
			end
		end
		Expect(Wrong).toBe(0)
		Expect(Cache.Count).toBe(#Order)
	end)

	Test("a limit that is not a whole number of at least 1 is refused", function()
		for _, Limit in { 0, -1, 1.5 } do
			Expect(function()
				Lru.New(Limit)
			end).toThrow(`Lru: the limit {Limit} is not a whole number of at least 1`)
		end
	end)
end)

return nil
