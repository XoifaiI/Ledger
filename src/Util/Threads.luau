--!strict
--!optimize 2

-- resume a parked thread, but only if its still parked, so one dead waiter cant strand a wake up loop

local function Resume(Thread: thread, ...: any): boolean
	if coroutine.status(Thread) ~= "suspended" then
		return false
	end

	task.spawn(Thread, ...)
	return true
end

return table.freeze({
	Resume = Resume
})
