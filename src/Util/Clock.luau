--!strict
--!optimize 2

--[=[

	Clock: The scheduler for the places that have no store to be handed one.

	Four places read this. The time written on an op, and the poll a session does while a leg is
	stuck. The timeout on a Future, and the watch on a slow listener. Use points it at a scheduler,
	and checks that one reads seconds since 1970.

	Return type: A table with Use, Held, Now, Wait, Delay and Cancel.
	Example usage:
		local Clock = require("./Clock")
		Clock.Use(Turn)
		local At = Clock.Now()
--]=]

local Engine = require("./Engine")
local Roblox = require("../Schedulers/Roblox")

local YEAR = 31556952
local CENTURY = 100 * YEAR

local Real = Roblox.New()
local Current: Engine.Scheduler = Real

local function Validate(Reads: () -> number)
	local Ok, Value = pcall(Reads)
	assert(Ok and type(Value) == "number" and Value == Value and Value ~= math.huge and Value ~= -math.huge, "the scheduler given to Ledger has to read a number of seconds")

	local Held = Real.Now()
	if math.abs(Value - Held) <= CENTURY then
		return
	end

	warn(`Ledger: the clock you gave reads {Value} and the real one reads {Held}. Ledger counts in seconds since 1970, so give it seconds`)
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
