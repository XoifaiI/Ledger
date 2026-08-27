--!strict
--!optimize 2

--[=[
	Clock: Gives the time that Ledger writes on a record, and the wait that Ledger polls on.

	A test can replace the source of the time and the wait. The test can then hold the time still or
	move it forward. The defaults are os.time and task.wait.
	Ledger counts each of its windows in seconds since 1970. Clock reads a new source one time and
	compares it against the real clock, because a source in other units would make a key forget the
	names that stop a payment happening two times.

	Return type: A table with Set, Now and Wait.
	Example usage:
		local Clock = require("./Clock")
		Clock.Set(function() return 1000 end)
		local At = Clock.Now()
--]=]

local Say = require("../Tools/Say")

local CENTURY = 100 * 31556952

local function Real(): number
	return os.time()
end

local function Sleep(Seconds: number)
	task.wait(Seconds)
end

local Source: () -> number = Real
local Waits: (Seconds: number) -> () = Sleep

local function Vet(Reads: () -> number)
	local Ok, Value = pcall(Reads)
	assert(Ok and type(Value) == "number" and Value == Value and Value ~= math.huge and Value ~= -math.huge, "the clock given to Ledger.UseClock has to give back a number of seconds")

	local Held = Real()
	if math.abs(Value - Held) <= CENTURY then
		return
	end

	Say.Warn(`Ledger: the clock you gave reads {Value} and the real one reads {Held}. Ledger counts in seconds since 1970, so give it seconds`)
end

local function Set(Reads: (() -> number)?, Sleeps: ((Seconds: number) -> ())?)
	if Reads ~= nil then
		Vet(Reads)
	end
	assert(Sleeps == nil or type(Sleeps) == "function", "the wait given to Ledger.UseClock has to be a function that takes a number of seconds")
	Source = Reads or Real
	Waits = Sleeps or Sleep
end

local function Now(): number
	return Source()
end

local function Wait(Seconds: number)
	Waits(Seconds)
end

return table.freeze({
	Set = Set,
	Now = Now,
	Wait = Wait,
})
