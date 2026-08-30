--!strict
--!optimize 2

--[=[

	Threads: Holds the pools of spare threads.

	A pool keeps a thread that finished so the next caller does not build one. Reset empties every
	pool at once, so a run that starts after another builds the same threads as one starting cold.

	Return type: A table with Pool and Reset.
	Example usage:
		local Threads = require("./Threads")
		local Idle = Threads.Pool()
--]=]

local Pools: { { thread } } = {}

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
	Pool = Pool,
	Reset = Reset,
})
