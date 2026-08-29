--!strict
--!optimize 2

--[=[
	Roblox: The scheduler Ledger runs on in a live game.

	It is the task library and the wall clock, behind the one shape everything else takes. Nothing
	here holds state, so New hands back the same set of functions every time and two stores sharing
	it share nothing but the engine they were already sharing.
	Cancel checks first, because a thread that has already finished is not the engine's to cancel and
	saying so is cheaper than the error.

	Return type: A table with New. It answers the Scheduler shape.
	Example usage:
		local Roblox = require("./Roblox")
		local Held = Roblox.New()
--]=]

local Engine = require("../Util/Engine")

export type Scheduler = Engine.Scheduler

local function Now(): number
	return os.time()
end

local function Wait(Seconds: number)
	task.wait(Seconds)
end

local function Spawn(Body: (...any) -> (), ...: any): thread
	return task.spawn(Body, ...)
end

local function Resume(Thread: thread, ...: any): boolean
	if coroutine.status(Thread) ~= "suspended" then
		return false
	end

	task.spawn(Thread, ...)
	return true
end

local function Defer(Body: (...any) -> (), ...: any): thread
	return task.defer(Body, ...)
end

local function Delay(Seconds: number, Body: (...any) -> (), ...: any): thread
	return task.delay(Seconds, Body, ...)
end

local function Cancel(Thread: thread)
	if coroutine.status(Thread) ~= "suspended" then
		return
	end

	task.cancel(Thread)
end

local Held: Scheduler = table.freeze({
	Now = Now,
	Wait = Wait,
	Spawn = Spawn,
	Resume = Resume,
	Defer = Defer,
	Delay = Delay,
	Cancel = Cancel,
})

local function New(): Scheduler
	return Held
end

return table.freeze({
	New = New,
})
