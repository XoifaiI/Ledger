--!strict
--!optimize 2

--[=[

	SetInterval: Calls a function again after each interval.

	The function runs on its own thread, on the scheduler it was handed, and cancelling that thread
	stops it. Offset waits a different amount before the first call, so timers started together do
	not stay together.

	Return type: A function that gives back the thread.
	Example usage:
		local SetInterval = require("./SetInterval")
		local Ticker = SetInterval(Scheduler, 30, Save)
		Scheduler.Cancel(Ticker)
--]=]

local Engine = require("./Engine")

local function SetInterval(Scheduler: Engine.Scheduler, Seconds: number, Callback: (Count: number) -> (), Offset: number?): thread
	return Scheduler.Spawn(function()
		local Count = 0
		if Offset ~= nil and Offset > 0 then
			Scheduler.Wait(Offset)
		end

		while true do
			Scheduler.Wait(Seconds)
			Count += 1
			local Ok, Err = pcall(Callback, Count)
			if not Ok then
				warn(`Ledger: SetInterval callback errored: {Err}`)
			end
		end
	end)
end

return SetInterval
