--!strict
--!optimize 2

--[=[
    ThreadQueue: serial task queue, SubmitAsync yields until your task runs in order and hands back its results so retries never reorder writes

    Return type: frozen table { New }
    Example usage:
        local ThreadQueue = require("./ThreadQueue")
        local Queue = ThreadQueue.New()
        local Result = Queue:SubmitAsync(function()
            return DoWork()
        end)
--]=]

type Entry = {
	Callback: () -> ...any,
	Caller: thread,
}

type ThreadQueueImpl = {
	__index: ThreadQueueImpl,
	SubmitAsync: (self: ThreadQueue, Callback: () -> ...any) -> ...any,
	GetLength: (self: ThreadQueue) -> number,
	SkipToLastEnqueued: (self: ThreadQueue) -> (),
}

export type ThreadQueue = setmetatable<{
	Tasks: { Entry },
	Busy: boolean,
}, ThreadQueueImpl>

local ThreadQueue = {} :: ThreadQueueImpl
ThreadQueue.__index = ThreadQueue

local function Drain(self: ThreadQueue)
	while self.Tasks[1] do
		local Entry = table.remove(self.Tasks, 1) :: Entry
		local Result = table.pack(pcall(Entry.Callback))
		if coroutine.status(Entry.Caller) == "suspended" then
			task.spawn(Entry.Caller, table.unpack(Result, 1, Result.n))
		end
	end
	self.Busy = false
end

function ThreadQueue.SubmitAsync(self: ThreadQueue, Callback: () -> ...any): ...any
	table.insert(self.Tasks, { Callback = Callback, Caller = coroutine.running() })

	if not self.Busy then
		self.Busy = true
		task.defer(Drain, self)
	end

	local Result = table.pack(coroutine.yield())
	if not Result[1] then
		error(Result[2], 0)
	end
	return table.unpack(Result, 2, Result.n)
end

function ThreadQueue.GetLength(self: ThreadQueue): number
	return #self.Tasks
end

function ThreadQueue.SkipToLastEnqueued(self: ThreadQueue)
	local Count = #self.Tasks
	if Count == 0 then
		return
	end

	local Dropped = table.move(self.Tasks, 1, Count - 1, 1, {})
	local Last = self.Tasks[Count]
	table.clear(self.Tasks)
	self.Tasks[1] = Last

	for _, Entry in Dropped do
		if coroutine.status(Entry.Caller) == "suspended" then
			task.spawn(Entry.Caller, false, "ThreadQueue task skipped")
		end
	end
end

local function New(): ThreadQueue
	return setmetatable({
		Tasks = {},
		Busy = false,
	}, ThreadQueue) :: ThreadQueue
end

table.freeze(ThreadQueue)

return table.freeze({
	New = New,
})
