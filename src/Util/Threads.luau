--!strict
--!optimize 2

--[=[
	Threads: the threads Ledger starts and the seconds they wait. Now reads os.clock, which only rises and has
	no date, so it times durations and is not the protocol's clock, which Shell/Platform reads. Scheduler gives
	the scheduler Observer spawns its listeners on. HasFrame finds a function on a live thread's stack; a dead one
	keeps its stack for tracebacks.

	Return type: A table with Now, Spawn, Delay, Cancel, Scheduler and HasFrame.
	Example usage:
		local Started = Threads.Now()
		local Watch = Threads.Delay(10, Warn)
		Threads.Cancel(Watch)
--]=]

export type Scheduler = {
	Now: () -> number,
	Spawn: <Args...>(Body: (Args...) -> (), Args...) -> thread,
	Delay: <Args...>(Seconds: number, Body: (Args...) -> (), Args...) -> thread,
	Cancel: (Thread: thread) -> (),
}

local DeadStatus = "dead"

local function Now(): number
	return os.clock()
end

local function Spawn<Args...>(Body: (Args...) -> (), ...: Args...): thread
	return task.spawn(Body, ...)
end

local function Delay<Args...>(Seconds: number, Body: (Args...) -> (), ...: Args...): thread
	return task.delay(Seconds, Body, ...)
end

local function Cancel(Thread: thread)
	task.cancel(Thread)
end

local TaskScheduler: Scheduler = {
	Now = Now,
	Spawn = Spawn,
	Delay = Delay,
	Cancel = Cancel,
}

local function Scheduler(): Scheduler
	return TaskScheduler
end

local function HasFrame(Thread: thread, Function: unknown): boolean
	if coroutine.status(Thread) == DeadStatus then
		return false
	end
	local Level = 0
	local Found = debug.info(Thread, Level, "f")
	while Found ~= nil do
		if Found == Function then
			return true
		end
		Level += 1
		Found = debug.info(Thread, Level, "f")
	end
	return false
end

return {
	Now = Now,
	Spawn = Spawn,
	Delay = Delay,
	Cancel = Cancel,
	Scheduler = Scheduler,
	HasFrame = HasFrame,
}
