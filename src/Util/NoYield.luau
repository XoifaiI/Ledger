--!strict
--!optimize 2

-- runs a callback that must finish synchronously, throwing with a traceback if it yields

local YIELDED = "the callback must complete without yielding"

local function Finish(Thread: thread, Success: boolean, ...: any): ...any
	if not Success then
		local Reason: string = tostring((...))
		error(debug.traceback(Thread, Reason), 2)
	end

	if coroutine.status(Thread) ~= "dead" then
		error(debug.traceback(Thread, YIELDED), 2)
	end

	return ...
end

local function NoYield<T...>(Callback: (T...) -> ...any, ...: T...): ...any
	local Thread = coroutine.create(Callback)
	return Finish(Thread, coroutine.resume(Thread, ...))
end

return NoYield
