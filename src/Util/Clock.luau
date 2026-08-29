--!strict
--!optimize 2

--[=[
	Clock: The scheduler for the handful of places that have no store to be handed one.

	A store is given its scheduler and a hook when it is built. Some things Ledger does are not
	reached through a store at all: the time written on an op, the poll a session does while a leg is
	stuck, the timeout on a Future a game waits on, and the watch on a slow listener. Those read this
	one instead, and a harness points it at the same scheduler it gave the stores.
	It reads a new source once and compares it against the real clock, because a source in other
	units would make a key forget the names that stop a payment happening two times.

	Return type: A table with Use, Held, Now, Wait, Delay and Cancel.
	Example usage:
		local Clock = require("./Clock")
		Clock.Use(Virtual.Bind(Turn))
		local At = Clock.Now()
--]=]

local Engine = require("./Engine")
local Roblox = require("../Schedulers/Roblox")

local Warnings = require("./Warnings")

local CENTURY = 100 * 31556952

local Real = Roblox.New()
local Current: Engine.Scheduler = Real

local function Validate(Reads: () -> number)
	local Ok, Value = pcall(Reads)
	assert(Ok and type(Value) == "number" and Value == Value and Value ~= math.huge and Value ~= -math.huge, "the scheduler given to Ledger has to read a number of seconds")

	local Held = Real.Now()
	if math.abs(Value - Held) <= CENTURY then
		return
	end

	Warnings.Warn(`Ledger: the clock you gave reads {Value} and the real one reads {Held}. Ledger counts in seconds since 1970, so give it seconds`)
end

local function Use(Scheduler: Engine.Scheduler?)
	if Scheduler ~= nil then
		Validate(Scheduler.Now)
	end
	Current = Scheduler or Real
end

local function Held(): Engine.Scheduler
	return Current
end

local function Now(): number
	return Current.Now()
end

local function Wait(Seconds: number)
	Current.Wait(Seconds)
end

local function Delay(Seconds: number, Body: (...any) -> (), ...: any): thread
	return Current.Delay(Seconds, Body, ...)
end

local function Cancel(Thread: thread)
	Current.Cancel(Thread)
end

return table.freeze({
	Use = Use,
	Held = Held,
	Now = Now,
	Wait = Wait,
	Delay = Delay,
	Cancel = Cancel,
})
