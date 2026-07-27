--!strict
--!optimize 2

-- runs the callback every interval on its own thread until you cancel the returned thread

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
