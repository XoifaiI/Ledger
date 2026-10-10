--!strict
--!optimize 2

--[=[
	NoYield: Runs a listener that must not yield. A listener that yields is stopped where it yielded,
	and one that throws is reported the same way; Try then answers false and the trace. Each listener
	runs on its own thread, which IsListening knows while it runs; a thread it wakes or spawns is not one.

	Return type: A table with Try and IsListening.
	Example usage:
		local Ok, Trace = NoYield.Try(Listener, Value)
--]=]

local YieldedMessage = "The listener yielded, so it was stopped. A listener must not yield."

local Listening: { [thread]: true } = {}
setmetatable(Listening, { __mode = "k" })

local function Stop(Thread: thread): string
	local Trace = debug.traceback(Thread, YieldedMessage)
	coroutine.close(Thread)
	return Trace
end

local function Try<Value>(Listener: (Value) -> (), Argument: Value): (boolean, string?)
	local Thread = coroutine.create(Listener)
	Listening[Thread] = true
	local Returned, Problem = coroutine.resume(Thread, Argument)
	Listening[Thread] = nil
	if not Returned then
		return false, debug.traceback(Thread, tostring(Problem))
	end

	if coroutine.status(Thread) == "suspended" then
		return false, Stop(Thread)
	end

	return true, nil
end

local function IsListening(): boolean
	return Listening[coroutine.running()] == true
end

return {
	Try = Try,
	IsListening = IsListening,
}
