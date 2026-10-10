--!strict
--!optimize 2

--[=[
	Stepping: marks the game code Ledger runs (the core's steps and transforms, the API's checks), so the API can
	refuse a Ledger call from it, on the marked thread or a coroutine that thread resumed. A mark holds only while Run
	is on its thread's stack, so a raise leaves none.

	Return type: A plain table with Run and IsStepping.
	Example usage:
		local _, Commands = Stepping.Run(Step.Step, State, Event)
		local IsInside = Stepping.IsStepping()
--]=]

local Threads = require("../Util/Threads")

local NormalStatus = "normal"

local Depths: { [thread]: number } = {}
setmetatable(Depths, { __mode = "k" })

local function Unmarked<Result...>(Thread: thread, ...: Result...): Result...
	local Depth = Depths[Thread] - 1
	Depths[Thread] = if Depth == 0 then nil else Depth
	return ...
end

local function Run<Args..., Result...>(Body: (Args...) -> Result..., ...: Args...): Result...
	local Thread = coroutine.running()
	Depths[Thread] = (Depths[Thread] or 0) + 1
	return Unmarked(Thread, Body(...))
end

local function IsStepping(): boolean
	local Current = coroutine.running()
	for Thread in Depths do
		if Thread == Current or coroutine.status(Thread) == NormalStatus then
			if Threads.HasFrame(Thread, Run) then
				return true
			end
			Depths[Thread] = nil
		end
	end
	return false
end

return {
	Run = Run,
	IsStepping = IsStepping,
}
