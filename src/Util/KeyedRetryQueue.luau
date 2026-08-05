--!strict
--!optimize 2

--[=[
	KeyedRetryQueue: Keeps the writes to one key in order.
	
	Each key has its own queue. A retry therefore cannot move in front of a write that came first.
	The Direct flag sends the call straight through with no queue.
	
	Return type: A table with Run and SkipAllToLastEnqueued.
	Example usage:
		local Queue = require("./KeyedRetryQueue")
		local Ok, Value = Queue.Run(State, "key", Call)
--]=]

local ThreadQueue = require("./ThreadQueue")
local RetryAsync = require("./RetryAsync")

type ThreadQueue = ThreadQueue.ThreadQueue

export type Handler = (() -> ...any) -> (boolean, ...any)

export type State = {
	Attempts: number?,
	Constant: number?,
	Exponent: number?,
	Jitter: number?,
	Direct: boolean?,
	Queues: { [string]: ThreadQueue }
}

local function RunUnqueued(State: State, Operation: () -> ...any, Handler: Handler?): ...any
	return RetryAsync(Operation, State, Handler)
end

local function Run(State: State, Key: string, Operation: () -> ...any, Handler: Handler?): ...any
	if State.Direct then
		return RunUnqueued(State, Operation, Handler)
	end

	local Queue = State.Queues[Key]
	if not Queue then
		Queue = ThreadQueue.New()
		State.Queues[Key] = Queue
	end

	local Result = table.pack(Queue:SubmitAsync(function()
		return RunUnqueued(State, Operation, Handler)
	end))

	if State.Queues[Key] == Queue and Queue:GetLength() == 0 then
		State.Queues[Key] = nil
	end

	return table.unpack(Result, 1, Result.n)
end

local function SkipAllToLastEnqueued(State: State)
	for _, Queue in State.Queues do
		Queue:SkipToLastEnqueued()
	end
end

return table.freeze({
	Run = Run,
	SkipAllToLastEnqueued = SkipAllToLastEnqueued
})
