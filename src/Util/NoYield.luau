--!strict
--!optimize 2

-- runs a callback that must finish synchronously, throwing with a traceback if it yields

local YIELDED = "the callback must complete without yielding"

local function Carried(Raised: any): boolean
	return type(Raised) == "table" and (Raised :: { Ledger: unknown }).Ledger == true
end

local function Finish(Thread: thread, Success: boolean, ...: any): ...any
	if not Success then
		local Raised: any = (...)
		if Carried(Raised) then
			error(Raised, 0)
		end
		error(debug.traceback(Thread, tostring(Raised)), 2)
	end

	if coroutine.status(Thread) ~= "dead" then
		local Trace = debug.traceback(Thread, YIELDED)
		coroutine.close(Thread)
		error(Trace, 2)
	end

	return ...
end

local function NoYield<T...>(Callback: (T...) -> ...any, ...: T...): ...any
	local Thread = coroutine.create(Callback)
	return Finish(Thread, coroutine.resume(Thread, ...))
end

return NoYield
