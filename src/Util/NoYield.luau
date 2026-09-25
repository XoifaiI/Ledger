--!strict
--!optimize 2

--[=[

	NoYield: Runs a function that must not yield.

	A function that yields is stopped, and the caller is told where. Run throws on a yield or a throw,
	and Try answers with a boolean instead. It keeps the threads that finished cleanly and uses them
	again. Two arguments reach the function and no more. A third would be dropped without a word.

	A stopped yield is raised as a value of its own that prints as its trace. Yielded tells it from a
	throw by what it is, never by its text. It passes through an outer guard unchanged, so a yield two
	deep still reads as a yield.

	Return type: A table with Run, Try and Yielded.
	Example usage:
		local NoYield = require("./NoYield")
		local Value = NoYield.Run(Callback, 1, 2)
--]=]

local Tagged = require("./Tagged")
local Threads = require("./Threads")

type Stopped = { Message: string }

local YIELDED = "the callback must complete without yielding"

local DONE = newproxy(false)
local Idle = Threads.Pool()

local Yield = table.freeze({
	__tostring = function(Raised: Stopped): string
		return Raised.Message
	end,
})

local function Yielded(Raised: unknown): boolean
	return type(Raised) == "table" and getmetatable(Raised :: any) == Yield
end

local function Settled(Raised: unknown): boolean
	return Tagged.Is(Raised) or Yielded(Raised)
end

local function Stop(Thread: thread): Stopped
	local Trace = debug.traceback(Thread, YIELDED)
	coroutine.close(Thread)
	return setmetatable({ Message = Trace }, Yield) :: any
end

local function Serve(Callback: (...any) -> ...any, First: any, Second: any): ...any
	return coroutine.yield(DONE, Callback(First, Second))
end

local function Worker()
	local Callback, First, Second = coroutine.yield()
	while true do
		Callback, First, Second = Serve(Callback, First, Second)
	end
end

local function Finish(Thread: thread, Success: boolean, Signal: any, ...: any): ...any
	if not Success then
		if Settled(Signal) then
			error(Signal, 0)
		end
		error(debug.traceback(Thread, tostring(Signal)), 2)
	end

	if Signal ~= DONE then
		error(Stop(Thread), 0)
	end

	table.insert(Idle, Thread)
	return ...
end

local function Answer(Thread: thread, Success: boolean, Signal: any, ...: any): (boolean, ...any)
	if not Success then
		if Settled(Signal) then
			return false, Signal
		end
		return false, debug.traceback(Thread, tostring(Signal))
	end

	if Signal ~= DONE then
		return false, Stop(Thread)
	end

	table.insert(Idle, Thread)
	return true, ...
end

local function Take(): thread
	local Count = #Idle
	if Count == 0 then
		local Fresh = coroutine.create(Worker)
		coroutine.resume(Fresh)
		return Fresh
	end

	local Thread = Idle[Count]
	Idle[Count] = nil
	return Thread
end

local function Run(Callback: (...any) -> ...any, First: any?, Second: any?): ...any
	local Thread = Take()
	return Finish(Thread, coroutine.resume(Thread, Callback, First, Second))
end

local function Try(Callback: (...any) -> ...any, First: any?, Second: any?): (boolean, ...any)
	local Thread = Take()
	return Answer(Thread, coroutine.resume(Thread, Callback, First, Second))
end

return table.freeze({
	Run = Run,
	Try = Try,
	Yielded = Yielded,
})
