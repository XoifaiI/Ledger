--!strict

--[=[

	Future: The cases for Util/Future.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Future = require("../src/Util/Future")

local Describe, Test, Expect, Similar = Testing.Describe, Testing.Test, Testing.Expect, Testing.Similar

type Box = { Answer: { [any]: any }? }

local function Pack(...: any): { [any]: any }
	return table.pack(...)
end

local function Waiter<T...>(Job: Future.Future<T...>, Into: Box, Timeout: number?)
	task.spawn(function()
		Into.Answer = Pack(Job:Wait(Timeout))
	end)
end

Describe("Future", function()
	Test("a completed future answers at once", function()
		local Job = Future.Completed(true, "x")
		Expect({ Job:Wait() }).toBe(Similar({ true, "x" }))
		Expect(Job:Happened()).toBe(true)
	end)

	Test("a pending future wakes every waiter with the answer, nils kept", function()
		local Job, Settle = Future.Pending()
		local First: Box, Second: Box = {}, {}
		Waiter(Job, First)
		Waiter(Job, Second)
		Expect(Job:Happened()).toBe(false)
		Expect(First.Answer).toBeNil()
		Settle(nil, "Busy")
		Expect(First.Answer).toBe(Similar({ n = 2, [2] = "Busy" }))
		Expect(Second.Answer).toBe(Similar({ n = 2, [2] = "Busy" }))
		Expect(Job:Happened()).toBe(true)
		Expect({ Job:Wait() }).toBe(Similar({ nil, "Busy" }))
	end)

	Test("a future settles once", function()
		local _, Settle = Future.Pending()
		Settle(true)
		Expect(function()
			Settle(true)
		end).toThrow("a future settled twice, so a thread waiting on it would read the wrong answer")
	end)

	Test("a wait that times out gives back nothing and misses the late answer", function()
		local Job, Settle = Future.Pending()
		local Timed: Box, Patient: Box = {}, {}
		Waiter(Job, Timed, 0.01)
		Waiter(Job, Patient)
		task.wait(0.05)
		Expect(Timed.Answer).toBe(Similar({ n = 0 }))
		Expect(Patient.Answer).toBeNil()
		Settle(7)
		Expect(Timed.Answer).toBe(Similar({ n = 0 }))
		Expect(Patient.Answer).toBe(Similar({ n = 1, 7 }))
	end)

	Test("an answer before the timeout cancels the timer", function()
		local Job, Settle = Future.Pending()
		local Timed: Box = {}
		Waiter(Job, Timed, 0.02)
		Settle(3)
		Expect(Timed.Answer).toBe(Similar({ n = 1, 3 }))
		task.wait(0.05)
		Expect(Timed.Answer).toBe(Similar({ n = 1, 3 }))
	end)

	Test("happened waits when asked to", function()
		local Job, Settle = Future.Pending()
		task.delay(0.01, Settle, true)
		Expect(Job:Happened(true)).toBe(true)
		Expect(Job:Wait()).toBe(true)
	end)
end)

return nil
