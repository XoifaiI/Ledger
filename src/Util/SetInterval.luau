--!strict
--!optimize 2

--[=[
	SetInterval: Calls a function again after each interval.

	The function runs on its own thread. Cancel that thread to stop it.
	Offset waits a different amount before the first call. Timers that start together therefore do
	not stay together and call the datastore in one burst.

	Return type: A function that gives back the thread.
	Example usage:
		local SetInterval = require("./SetInterval")
		local Ticker = SetInterval(30, Save)
		task.cancel(Ticker)
--]=]

local Say = require("./Say")

local function SetInterval(Seconds: number, Callback: (Count: number) -> (), Offset: number?): thread
	return task.spawn(function()
		local Count = 0
		if Offset ~= nil and Offset > 0 then
			task.wait(Offset)
		end

		while task.wait(Seconds) do
			Count += 1
			local Ok, Err = pcall(Callback, Count)
			if not Ok then
				Say.Warn(`Ledger: SetInterval callback errored: {Err}`)
			end
		end
	end)
end

return SetInterval
