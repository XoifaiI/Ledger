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
		local Stream: Observer.Observer<number> = Observer.New()
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
		local Stream: Observer.Observer<number> = Observer.New()
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
		local Stream: Observer.Observer<number> = Observer.New()
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

	Test("destroy disconnects every listener", function()
		local Stream: Observer.Observer<number> = Observer.New()
		local Seen = 0
		local Connection = Stream:Subscribe(function()
			Seen += 1
		end)
		Stream:Destroy()
		Stream:Push(1)
		Expect(Seen).toBe(0)
		Expect(Connection.Connected).toBe(false)
	end)
end)

return nil
