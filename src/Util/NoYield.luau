--!strict
--!optimize 2

--[=[
	NoYield: Runs a function that must not yield.

	If the function yields, this throws and shows you where.
	An error that carries a reason goes through unchanged, because the caller reads that reason.
	A thread that finished is kept and used again. One that threw or yielded is not, so a thread is
	only ever handed out in a state it can run from.
	The callback takes up to two arguments and gives back as many values as it likes.

	Run throws when the callback throws or yields. Try answers whether it went through instead, so a
	caller that was going to catch the throw does not pay for one being raised.

	Return type: A table with Run and Try.
	Example usage:
		local NoYield = require("./NoYield")
		local Value = NoYield.Run(Callback, 1, 2)
--]=]

local YIELDED = "the callback must complete without yielding"

local DONE = newproxy(false)
local Idle: { thread } = {}

local function Carried(Raised: any): boolean
	return type(Raised) == "table" and (Raised :: { Ledger: unknown }).Ledger == true
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
		if Carried(Signal) then
			error(Signal, 0)
		end
		error(debug.traceback(Thread, tostring(Signal)), 2)
	end

	if Signal ~= DONE then
		local Trace = debug.traceback(Thread, YIELDED)
		coroutine.close(Thread)
		error(Trace, 2)
	end

	table.insert(Idle, Thread)
	return ...
end

local function Answer(Thread: thread, Success: boolean, Signal: any, ...: any): (boolean, ...any)
	if not Success then
		if Carried(Signal) then
			return false, Signal
		end
		return false, debug.traceback(Thread, tostring(Signal))
	end

	if Signal ~= DONE then
		local Trace = debug.traceback(Thread, YIELDED)
		coroutine.close(Thread)
		return false, Trace
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
	Try = Try
})
