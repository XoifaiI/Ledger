--!strict
--!optimize 2

--[=[

	SetInterval: Calls a function again after each interval.

	The timer runs on its own thread, on the scheduler it was handed, and cancelling that thread
	stops it. Each call runs on a thread of its own that the timer waits for, so a cancel stops the
	calls to come and never kills one part way through a write that holds a key's queue. Offset waits a different amount before the first call, so timers started together do
	not stay together. A function that hands back a number of seconds is run next after that many,
	and one that hands back nothing keeps the interval it had.

	Return type: A function that gives back the thread.
	Example usage:
		local SetInterval = require("./SetInterval")
		local Ticker = SetInterval(Scheduler, 30, Save)
		Scheduler.Cancel(Ticker)
--]=]

local Engine = require("./Engine")
local Messages = require("../Core/Constants/Messages")

local function SetInterval(Scheduler: Engine.Scheduler, Seconds: number, Callback: (Count: number) -> ...number?, Offset: number?): thread
	return Scheduler.Spawn(function()
		local Count = 0
		local Interval = Seconds
		if Offset ~= nil and Offset > 0 then
			Scheduler.Wait(Offset)
		end

		local Ticker = coroutine.running()
		while true do
			Scheduler.Wait(Interval)
			Count += 1

			local Done = false
			local Ok, Next = true, nil :: any
			Scheduler.Spawn(function(At: number)
				Ok, Next = pcall(Callback, At)
				Done = true
				Scheduler.Resume(Ticker)
			end, Count)
			while not Done do
				coroutine.yield()
			end

			if not Ok then
				warn(`{Messages.ACCUSED} a job Ledger runs on a timer threw, and it keeps running. please report this: {Next}`)
			elseif type(Next) == "number" and Next > 0 then
				Interval = Next
			end
		end
	end)
end

return SetInterval
