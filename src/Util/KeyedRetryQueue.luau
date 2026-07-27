--!strict
--!optimize 2

-- per key serial queue around a retrying call, so retries never reorder writes to the same key

local ThreadQueue = require("./ThreadQueue")
local RetryAsync = require("./RetryAsync")

type ThreadQueue = ThreadQueue.ThreadQueue

export type Handler = (() -> ...any) -> (boolean, ...any)

export type State = {
	Attempts: number?,
	Constant: number?,
	Exponent: number?,
	Queues: { [string]: ThreadQueue }
}

local function RunUnqueued(State: State, Operation: () -> ...any, Handler: Handler?): ...any
	return RetryAsync(Operation, {
		Attempts = State.Attempts,
		Constant = State.Constant,
		Exponent = State.Exponent,
		Handler = Handler
	})
end

local function Run(State: State, Key: string, Operation: () -> ...any, Handler: Handler?): ...any
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
