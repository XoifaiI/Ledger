--!strict
--!optimize 2

--[=[
	Threads: Starts a thread again, but only if that thread waits. Holds the pools of spare threads.

	A thread that is dead stays dead. One dead thread therefore cannot stop a loop that wakes many threads.
	A pool keeps a thread that finished so the next caller does not build one. That is state the engine
	owns rather than a key does, so Reset empties every pool at once and a run that starts after one
	builds the same threads as a run that starts cold.

	Return type: A table with Resume, Pool and Reset.
	Example usage:
		local Threads = require("./Threads")
		Threads.Resume(Thread, Value)
--]=]

local Pools: { { thread } } = {}

local function Resume(Thread: thread, ...: any): boolean
	if coroutine.status(Thread) ~= "suspended" then
		return false
	end

	task.spawn(Thread, ...)
	return true
end

local function Pool(): { thread }
	local Held: { thread } = {}
	table.insert(Pools, Held)
	return Held
end

local function Reset()
	for _, Held in Pools do
		table.clear(Held)
	end
end

return table.freeze({
	Resume = Resume,
	Pool = Pool,
	Reset = Reset,
})
