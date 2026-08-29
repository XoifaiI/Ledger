--!strict
--!optimize 2

--[=[
	SetInterval: Calls a function again after each interval.

	The function runs on its own thread, on the scheduler it was handed. Cancel that thread to stop it.
	Offset waits a different amount before the first call. Timers that start together therefore do
	not stay together and call the datastore in one burst.

	Return type: A function that gives back the thread.
	Example usage:
		local SetInterval = require("./SetInterval")
		local Ticker = SetInterval(30, Save)
		task.cancel(Ticker)
--]=]

local Engine = require("./Engine")
local Warnings = require("./Warnings")

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
				Warnings.Warn(`Ledger: SetInterval callback errored: {Err}`)
			end
		end
	end)
end

return SetInterval
