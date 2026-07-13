--!strict
--!optimize 2

--[=[
    SetInterval: runs the callback every interval on its own thread until you cancel the returned thread, the callback gets the running tick count

    Return type: the SetInterval function, SetInterval(Seconds, Callback) -> thread
    Example usage:
        local SetInterval = require("./SetInterval")
        local Running = SetInterval(1, function(Count)
            print(Count)
        end)
        task.cancel(Running)
--]=]

local function SetInterval(Seconds: number, Callback: (Count: number) -> ()): thread
	return task.spawn(function()
		local Count = 0
		while task.wait(Seconds) do
			Count += 1
			local Ok, Err = pcall(Callback, Count)
			if not Ok then
				warn(`SetInterval callback errored: {Err}`)
			end
		end
	end)
end

return SetInterval
