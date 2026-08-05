--!strict
--!optimize 2

--[=[
	NoYield: Runs a function that must not yield.
	
	If the function yields, this throws and shows you where.
	An error that carries a reason goes through unchanged, because the caller reads that reason.
	
	Return type: A function that gives back what the callback returned.
	Example usage:
		local NoYield = require("./NoYield")
		local Value = NoYield(Callback, 1, 2)
--]=]

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
