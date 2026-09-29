--!strict

--[=[

	Observer: The cases for Util/Observer.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Observer = require("../src/Util/Observer")

local Describe, Test, Expect, Similar, Heard = Testing.Describe, Testing.Test, Testing.Expect, Testing.Similar, Testing.Heard

Describe("Observer", function()
	Test("a push reaches each listener in the order they subscribed", function()
		local Stream: Observer.Subject<number> = Observer.New()
		local Seen: { string } = {}
		Stream:Subscribe(function(Value: number)
			table.insert(Seen, `a{Value}`)
		end)
		local Second = Stream:Subscribe(function(Value: number)
			table.insert(Seen, `b{Value}`)
		end)
		Stream:Push(1)
		Second:Disconnect()
		Stream:Push(2)
		Expect(Seen).toBe(Similar({ "a1", "b1", "a2" }))
	end)

	Test("a listener that disconnects a later one during a push stops it at once", function()
		local Stream: Observer.Subject<number> = Observer.New()
		local Seen: { string } = {}
		local Later: Observer.Connection
		Stream:Subscribe(function()
			Later:Disconnect()
			Stream:Subscribe(function()
				table.insert(Seen, "new")
			end)
		end)
		Later = Stream:Subscribe(function()
			table.insert(Seen, "later")
		end)
		Stream:Push(1)
		Expect(Seen).toBe(Similar({}))
	end)

	Test("a listener that throws or yields is reported and the rest still run", function()
		Heard()
		local Stream: Observer.Subject<number> = Observer.New()
		local Resumed = false
		local Seen = 0
		Stream:Subscribe(function()
			error("boom", 0)
		end)
		Stream:Subscribe(function()
			coroutine.yield()
			Resumed = true
		end)
		Stream:Subscribe(function()
			Seen += 1
		end)
		Stream:Push(1)
		Expect(Seen).toBe(1)
		Expect(Resumed).toBe(false)
		Expect(Heard()).toBe(Similar({
			"Ledger: an Observer listener threw: boom",
			"Ledger: an Observer listener yielded and was stopped. a listener runs the moment a value is pushed",
		}))
	end)

	Test("from starts its source on the first subscriber and stops it after the last", function()
		local Started, Stopped = 0, 0
		local Emit: ((number) -> ())? = nil
		local Stream: Observer.Observer<number> = Observer.From(function(Give: (number) -> ())
			Started += 1
			Emit = Give
			return function()
				Stopped += 1
			end
		end)
		local Seen: { number } = {}
		local First = Stream:Subscribe(function(Value: number)
			table.insert(Seen, Value)
		end)
		local Second = Stream:Subscribe(function() end)
		Expect(Started).toBe(1);
		(Emit :: (number) -> ())(5)
		First:Disconnect()
		Expect(Stopped).toBe(0)
		Second:Disconnect()
		Expect(Stopped).toBe(1)
		Stream:Subscribe(function() end)
		Expect(Started).toBe(2)
		Expect(Seen).toBe(Similar({ 5 }))
	end)

	Test("map, filter and changed make streams from a stream", function()
		local Stream: Observer.Subject<number> = Observer.New()
		local Seen: { string } = {}
		Stream:Filter(function(Value: number): boolean
			return Value > 0
		end)
			:Changed()
			:Map(function(Value: number): string
				return `v{Value}`
			end)
			:Subscribe(function(Value: string)
				table.insert(Seen, Value)
			end)
		for _, Value in { 1, 1, -3, 2, 2, 1 } do
			Stream:Push(Value)
		end
		Expect(Seen).toBe(Similar({ "v1", "v2", "v1" }))
	end)

	Test("destroy stops the source and every listener", function()
		local Stopped = 0
		local Emit: ((number) -> ())? = nil
		local Stream: Observer.Observer<number> = Observer.From(function(Give: (number) -> ())
			Emit = Give
			return function()
				Stopped += 1
			end
		end)
		local Seen = 0
		local Connection = Stream:Subscribe(function()
			Seen += 1
		end)
		Stream:Destroy()
		Expect(Stopped).toBe(1)
		Expect(Connection.Connected).toBe(false);
		(Emit :: (number) -> ())(1)
		Expect(Seen).toBe(0)
		Connection:Disconnect()
		Expect(Stopped).toBe(1)
	end)

	Test("a detached stream runs each listener on a thread of its own", function()
		local Stream: Observer.Subject<number> = Observer.New(true)
		local Seen: { number } = {}
		Stream:Subscribe(function(Value: number)
			task.wait(0.01)
			table.insert(Seen, Value)
		end)
		Stream:Push(4)
		Expect(Seen).toBe(Similar({}))
		task.wait(0.05)
		Expect(Seen).toBe(Similar({ 4 }))
	end)
end)

return nil
