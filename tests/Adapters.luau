--!strict

--[=[

	Adapters: The cases for Adapters/DataStore and Adapters/MemoryStore.

	The stores here are fakes that fail on cue, so each case sees one outcome of one call.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local DataStore = require("../src/Adapters/DataStore")
local MemoryStore = require("../src/Adapters/MemoryStore")

type Transform = DataStore.Transform

local Describe, Test, Expect, Similar = Testing.Describe, Testing.Test, Testing.Expect, Testing.Similar

type Plan = {
	Runs: number,
	Before: string?,
	After: string?,
	Options: DataStoreGetOptions?,
}

local function Store(Values: { [string]: unknown }, Plan: Plan): DataStore.Store
	local Fake = {}
	function Fake.GetAsync(_: any, Key: string, Options: DataStoreGetOptions?): (unknown, DataStoreKeyInfo?)
		Plan.Options = Options
		if Plan.Before then
			error(Plan.Before, 0)
		end
		return Values[Key], nil
	end
	function Fake.UpdateAsync(_: any, Key: string, Transform: Transform): (unknown, DataStoreKeyInfo?)
		if Plan.Before then
			error(Plan.Before, 0)
		end
		local Next: unknown = nil
		for _ = 1, Plan.Runs do
			Next = Transform(Values[Key], nil)
		end
		if Plan.After then
			error(Plan.After, 0)
		end
		if Next ~= nil then
			Values[Key] = Next
		end
		return Next, nil
	end
	function Fake.RemoveAsync(_: any, Key: string): (unknown, DataStoreKeyInfo?)
		if Plan.After then
			error(Plan.After, 0)
		end
		local Old = Values[Key]
		Values[Key] = nil
		return Old, nil
	end
	return Fake
end

type Calls = { Count: number, Failing: boolean }

local function Map(Calls: Calls): MemoryStore.Map
	local Values: { [string]: unknown } = {}
	local Fake = {}
	local function Call()
		Calls.Count += 1
		if Calls.Failing then
			error("throttled", 0)
		end
	end
	function Fake.GetAsync(_: any, Key: string): unknown
		Call()
		return Values[Key]
	end
	function Fake.SetAsync(_: any, Key: string, Value: unknown, _: number): unknown
		Call()
		Values[Key] = Value
		return true
	end
	function Fake.UpdateAsync(_: any, Key: string, Transform: (Current: unknown) -> unknown, _: number): unknown
		Call()
		Values[Key] = Transform(Values[Key])
		return Values[Key]
	end
	function Fake.RemoveAsync(_: any, Key: string)
		Call()
		Values[Key] = nil
	end
	return Fake
end

local function Add(Amount: number): Transform
	return function(Current: unknown): (unknown, { number }?, { [string]: any }?)
		return (Current :: number? or 0) + Amount, nil, nil
	end
end

local function Cancel(): (unknown, { number }?, { [string]: any }?)
	return nil, nil, nil
end

Describe("DataStore", function()
	Test("a read answers the value", function()
		Expect({ DataStore.Get(Store({ a = 5 }, { Runs = 1 }), "a") }).toBe(Similar({ true, 5 }))
	end)

	Test("a read passes its options on, so it can skip the cache", function()
		local Plan: Plan = { Runs = 1 }
		local Options = { UseCache = false } :: any
		DataStore.Get(Store({}, Plan), "a", Options)
		Expect(Plan.Options).toBe(Options)
	end)

	Test("a read that fails answers the error", function()
		Expect({ DataStore.Get(Store({}, { Runs = 1, Before = "502: busy" }), "a") }).toBe(Similar({ false, "502: busy" }))
	end)

	Test("an update that lands answers what it wrote", function()
		local Values = { a = 1 }
		Expect({ DataStore.Update(Store(Values, { Runs = 1 }), "a", Add(10)) }).toBe(Similar({ true, 11, true }))
		Expect(Values.a).toBe(11)
	end)

	Test("an update whose every run cancels wrote nothing", function()
		local Values = { a = 1 }
		Expect({ DataStore.Update(Store(Values, { Runs = 3 }), "a", Cancel) }).toBe(Similar({ true, nil, false }))
		Expect(Values.a).toBe(1)
	end)

	Test("an update that fails after a run offered a write says it may have written", function()
		Expect({ DataStore.Update(Store({}, { Runs = 2, After = "timeout" }), "a", Add(1)) }).toBe(Similar({ false, "timeout", true }))
	end)

	Test("an update that fails before any run wrote nothing", function()
		Expect({ DataStore.Update(Store({}, { Runs = 1, Before = "throttled" }), "a", Add(1)) }).toBe(Similar({ false, "throttled", false }))
	end)

	Test("a transform that raises fails the call with its error", function()
		local function Broken(): (unknown, { number }?, { [string]: any }?)
			error("step raised", 0)
		end
		Expect({ DataStore.Update(Store({}, { Runs = 1 }), "a", Broken) }).toBe(Similar({ false, "step raised", false }))
	end)

	Test("a remove answers the value it removed, or the error", function()
		local Values = { a = 1 }
		Expect({ DataStore.Remove(Store(Values, { Runs = 1 }), "a") }).toBe(Similar({ true, 1 }))
		Expect(Values.a).toBeNil()
		Expect({ DataStore.Remove(Store({}, { Runs = 1, After = "lost" }), "a") }).toBe(Similar({ false, "lost" }))
	end)
end)

Describe("MemoryStore", function()
	Test("each call answers what the map gave back", function()
		local Cache = MemoryStore.New(Map({ Count = 0, Failing = false }))
		local function Double(Current: unknown): unknown
			return (Current :: number) * 2
		end
		Expect({ MemoryStore.Set(Cache, 0, "k", 4, 60) }).toBe(Similar({ true, true }))
		Expect({ MemoryStore.Get(Cache, 0, "k") }).toBe(Similar({ true, 4 }))
		Expect({ MemoryStore.Update(Cache, 0, "k", Double, 60) }).toBe(Similar({ true, 8 }))
		Expect({ MemoryStore.Remove(Cache, 0, "k") }).toBe(Similar({ true }))
		Expect({ MemoryStore.Get(Cache, 0, "k") }).toBe(Similar({ true }))
	end)

	Test("misses in a row stop the calls until the breaker passes", function()
		local Calls = { Count = 0, Failing = true }
		local Cache = MemoryStore.New(Map(Calls))
		for Try = 1, MemoryStore.MISSES do
			Expect({ MemoryStore.Get(Cache, 10, "k") }).toBe(Similar({ false, "throttled" }))
			Expect(Calls.Count).toBe(Try)
		end
		Expect({ MemoryStore.Get(Cache, 10 + MemoryStore.BREAKER - 1, "k") }).toBe(Similar({ false }))
		Expect(Calls.Count).toBe(MemoryStore.MISSES)

		Calls.Failing = false
		Expect({ MemoryStore.Get(Cache, 10 + MemoryStore.BREAKER, "k") }).toBe(Similar({ true }))
		Expect(Calls.Count).toBe(MemoryStore.MISSES + 1)
		Expect(Cache.Row).toBe(0)
	end)

	Test("an answer between misses clears the count", function()
		local Calls = { Count = 0, Failing = true }
		local Cache = MemoryStore.New(Map(Calls))
		for _ = 1, MemoryStore.MISSES - 1 do
			MemoryStore.Get(Cache, 0, "k")
		end
		Calls.Failing = false
		MemoryStore.Get(Cache, 0, "k")
		Calls.Failing = true
		for _ = 1, MemoryStore.MISSES - 1 do
			MemoryStore.Get(Cache, 0, "k")
		end
		Expect(Cache.Quiet).toBe(0)
	end)
end)

return nil
