--!strict
--!optimize 2

--[=[

	Queue: A first in first out queue.

	Push and Pop cost O(1). Pop gives back nil when the queue is empty.

	Return type: A table with New, Push, Pop and Length.
	Example usage:
		local Queue = require("./Queue")
		local Pending: Queue.Queue<number> = Queue.New()
		Queue.Push(Pending, 1)
		local First = Queue.Pop(Pending)
--]=]

export type Queue<T> = {
	Items: { [number]: T },
	Head: number,
	Tail: number,
}

local function New(): Queue<any>
	return { Items = {}, Head = 1, Tail = 0 }
end

local function Push<T>(Pending: Queue<T>, Value: T)
	local Tail = Pending.Tail + 1
	Pending.Tail = Tail
	Pending.Items[Tail] = Value
end

local function Pop<T>(Pending: Queue<T>): T?
	local Head = Pending.Head
	if Head > Pending.Tail then
		return nil
	end
	local Value = Pending.Items[Head]
	Pending.Items[Head] = nil
	Pending.Head = Head + 1
	return Value
end

local function Length<T>(Pending: Queue<T>): number
	return Pending.Tail - Pending.Head + 1
end

return table.freeze({
	New = New,
	Push = Push,
	Pop = Pop,
	Length = Length,
})
