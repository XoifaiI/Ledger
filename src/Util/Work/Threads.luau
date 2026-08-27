--!strict
--!optimize 2

--[=[
	Threads: Starts a thread again, but only if that thread waits.

	A thread that is dead stays dead. One dead thread therefore cannot stop a loop that wakes many threads.

	Return type: A table with Resume.
	Example usage:
		local Threads = require("./Threads")
		Threads.Resume(Thread, Value)
--]=]

local function Resume(Thread: thread, ...: any): boolean
	if coroutine.status(Thread) ~= "suspended" then
		return false
	end

	task.spawn(Thread, ...)
	return true
end

return table.freeze({
	Resume = Resume,
})
