--!strict
--!optimize 2

--[=[
	ThreadQueue: Runs tasks one after the other.

	SubmitAsync waits until your task runs, then gives you what the task returned.
	SkipToLastEnqueued removes all tasks but the last one. Each removed caller gets an error.
	The queue records the thread that runs a task. If that thread dies before the task ends, the next
	caller takes the queue. Without this a cancelled thread stops the queue for the life of the server.

	Return type: A table with New and the SKIPPED message.
	Example usage:
		local ThreadQueue = require("./ThreadQueue")
		local Queue = ThreadQueue.New()
		local Value = Queue:SubmitAsync(Work)
--]=]

local Engine = require("./Engine")
local Warnings = require("./Warnings")

type Entry = {
	Callback: () -> ...any,
	Caller: thread,
}

type ThreadQueueImpl = {
	__index: ThreadQueueImpl,
	New: (Scheduler: Engine.Scheduler) -> ThreadQueue,
	Abandoned: (self: ThreadQueue) -> boolean,
	Drain: (self: ThreadQueue) -> (),
	SubmitAsync: (self: ThreadQueue, Callback: () -> ...any) -> ...any,
	GetLength: (self: ThreadQueue) -> number,
	SkipToLastEnqueued: (self: ThreadQueue) -> (),
}

export type ThreadQueue = setmetatable<{
	Scheduler: Engine.Scheduler,
	Tasks: { Entry },
	Busy: boolean,
	Holder: thread?,
}, ThreadQueueImpl>

local SKIPPED = "ThreadQueue task skipped"

local function TraceHandler(Err: any): string
	return debug.traceback(tostring(Err), 1)
end

local ThreadQueue = {} :: ThreadQueueImpl
ThreadQueue.__index = ThreadQueue

function ThreadQueue.New(Scheduler: Engine.Scheduler): ThreadQueue
	return setmetatable({
		Scheduler = Scheduler,
		Tasks = {},
		Busy = false,
		Holder = nil,
	}, ThreadQueue) :: ThreadQueue
end

function ThreadQueue.Abandoned(self: ThreadQueue): boolean
	local Holder = self.Holder
	return Holder ~= nil and coroutine.status(Holder) == "dead"
end

function ThreadQueue.Drain(self: ThreadQueue)
	assert(self.Busy, "the queue is draining without being marked busy, so a second drain could run beside it")
	self.Holder = coroutine.running()
	while self.Tasks[1] do
		local Entry = table.remove(self.Tasks, 1) :: Entry
		local Result = table.pack(xpcall(Entry.Callback, TraceHandler))
		if coroutine.status(Entry.Caller) == "suspended" then
			task.spawn(Entry.Caller, table.unpack(Result, 1, Result.n))
		end
	end
	self.Holder = nil
	self.Busy = false
end

function ThreadQueue.SubmitAsync(self: ThreadQueue, Callback: () -> ...any): ...any
	if not self.Busy or self:Abandoned() then
		if self.Busy then
			Warnings.Warn(`Ledger: ThreadQueue took over a queue whose thread was cancelled, {#self.Tasks} task(s) were waiting on it`)
		end

		self.Busy = true
		self.Holder = coroutine.running()
		local Straight = table.pack(xpcall(Callback, TraceHandler))

		self.Holder = nil
		if self.Tasks[1] then
			self.Scheduler.Defer(self.Drain, self)
		else
			self.Busy = false
		end

		if not Straight[1] then
			error(Straight[2], 0)
		end
		return table.unpack(Straight, 2, Straight.n)
	end

	table.insert(self.Tasks, { Callback = Callback, Caller = coroutine.running() })

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
	assert(Last ~= nil, "the queue lost the task it was told to keep")
	table.clear(self.Tasks)
	self.Tasks[1] = Last

	for _, Entry in Dropped do
		if coroutine.status(Entry.Caller) == "suspended" then
			task.spawn(Entry.Caller, false, SKIPPED)
		end
	end
end

table.freeze(ThreadQueue)

return table.freeze({
	New = ThreadQueue.New,
	SKIPPED = SKIPPED,
})
