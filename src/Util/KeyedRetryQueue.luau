--!strict
--!optimize 2

--[=[
    KeyedRetryQueue: the shared chassis behind the store wrappers, a per-key serial queue around
    a retrying call so retries never reorder writes to the same key.

    a wrapper embeds the State fields and hands itself in, which keeps Attempts a plain mutable
    field on the wrapper (shutdown lowers it on the fly) while both wrappers share one queue and
    retry engine. queues are created on first use per key and dropped again once empty.

    Return type: frozen table { Run, RunUnqueued, GetLength, AllEmpty, SkipAllToLastEnqueued }
    Example usage:
        local KeyedRetryQueue = require("./KeyedRetryQueue")
        local Ok, Value = KeyedRetryQueue.Run(self, Key, function()
            return Store:GetAsync(Key)
        end, Handler)
--]=]

local ThreadQueue = require("./ThreadQueue")
local RetryAsync = require("./RetryAsync")

type ThreadQueue = ThreadQueue.ThreadQueue

export type Handler = (() -> ...any) -> (boolean, ...any)

export type State = {
	Attempts: number?,
	Constant: number?,
	Exponent: number?,
	Queues: { [string]: ThreadQueue },
}

local function RunUnqueued(State: State, Operation: () -> ...any, Handler: Handler?): ...any
	return RetryAsync(Operation, {
		Attempts = State.Attempts,
		Constant = State.Constant,
		Exponent = State.Exponent,
		Handler = Handler,
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

local function GetLength(State: State, Key: string): number
	local Queue = State.Queues[Key]
	return if Queue then Queue:GetLength() else 0
end

local function AllEmpty(State: State): boolean
	for _, Queue in State.Queues do
		if Queue:GetLength() > 0 then
			return false
		end
	end
	return true
end

local function SkipAllToLastEnqueued(State: State)
	for _, Queue in State.Queues do
		Queue:SkipToLastEnqueued()
	end
end

return table.freeze({
	Run = Run,
	RunUnqueued = RunUnqueued,
	GetLength = GetLength,
	AllEmpty = AllEmpty,
	SkipAllToLastEnqueued = SkipAllToLastEnqueued,
})
