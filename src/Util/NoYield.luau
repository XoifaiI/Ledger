--!strict
--!optimize 2

--[=[
    NoYield: runs a callback that must complete synchronously, throwing with a traceback if it yields or errors.

    a datastore UpdateAsync transform fails the whole call if it yields, and a reducer that yields
    mid fold would make replays nondeterministic, so the data layer runs both through this. the
    callback runs on its own thread, a yield leaves that thread suspended instead of the caller,
    and that is detected and raised as an error pointing at the yield site.

    Return type: the NoYield function
    Example usage:
        local NoYield = require("./NoYield")
        local Doubled = NoYield(function(Value: number)
            return Value * 2
        end, 5)
--]=]

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
