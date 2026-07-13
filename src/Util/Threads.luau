--!strict
--!optimize 2

--[=[
    Threads: reusable coroutine pool, spawn fire and forget work without allocating a fresh thread each time

    Return type: frozen table { Spawn, Resume }
    Example usage:
        local Threads = require("./Threads")
        Threads.Spawn(function(Message: string)
            print(Message)
        end, "hello")
        Threads.Resume(Waiter, Result)
--]=]

local Free: {thread} = {}

local function Run(Callback: (...any) -> (), ...: any)
	local Thread = coroutine.running()
	Callback(...)
	table.insert(Free, Thread)
end

local function Loop()
	while true do
		Run(coroutine.yield())
	end
end

local function Spawn<T...>(Callback: (T...) -> (), ...: T...)
	local Thread: thread
	local Count = #Free

	if Count > 0 then
		Thread = Free[Count]
		Free[Count] = nil
	else
		Thread = coroutine.create(Loop)
		coroutine.resume(Thread)
	end

	task.spawn(Thread, Callback, ...)
end

local function Resume(Thread: thread, ...: any): boolean
	if coroutine.status(Thread) ~= "suspended" then
		return false
	end

	task.spawn(Thread, ...)
	return true
end

return table.freeze({
	Spawn = Spawn,
	Resume = Resume,
})
