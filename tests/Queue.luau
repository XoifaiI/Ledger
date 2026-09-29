--!strict

--[=[

	Queue: The cases for Util/Queue.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Queue = require("../src/Util/Queue")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

Describe("Queue", function()
	Test("pop gives back values in the order they were pushed", function()
		local Pending: Queue.Queue<number> = Queue.New()
		Queue.Push(Pending, 1)
		Queue.Push(Pending, 10)
		Expect(Queue.Pop(Pending)).toBe(1)
		Queue.Push(Pending, 100)
		Expect(Queue.Length(Pending)).toBe(2)
		Expect(Queue.Pop(Pending)).toBe(10)
		Expect(Queue.Pop(Pending)).toBe(100)
	end)

	Test("an empty queue pops nil and takes pushes again", function()
		local Pending: Queue.Queue<number> = Queue.New()
		Expect(Queue.Pop(Pending)).toBeNil()
		Expect(Queue.Length(Pending)).toBe(0)
		Queue.Push(Pending, 7)
		Expect(Queue.Pop(Pending)).toBe(7)
		Expect(Queue.Pop(Pending)).toBeNil()
		Expect(Queue.Length(Pending)).toBe(0)
	end)
end)

return nil
