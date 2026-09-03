--!strict
--!optimize 2

--[=[

	Roblox: The scheduler Ledger runs on in a live game.

	The task library, the wall clock and one generator for the rolls, behind the shape everything else
	takes. It holds nothing a run can change, so New hands back the same set of functions every time.

	Return type: A table with New. It answers the Scheduler shape.
	Example usage:
		local Roblox = require("./Roblox")
		local Held = Roblox.New()
--]=]

local Engine = require("../Util/Engine")

export type Scheduler = Engine.Scheduler

local Rolls = Random.new()

local function Now(): number
	return os.time()
end

local function Roll(): number
	return Rolls:NextNumber()
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
	Roll = Roll,
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
