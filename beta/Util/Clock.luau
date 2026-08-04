--!strict
--!optimize 2

--[=[
	Clock: Gives the time that Ledger writes on a record.
	
	A test can replace the source of the time. The test can then hold the time still, or move it forward.
	The default source is os.time.
	Ledger counts each of its windows in seconds since 1970. A new source is read once and checked
	against the real clock. A source in other units would make a key forget the names that stop a
	payment happening two times.

	Return type: A table with Set and Now.
	Example usage:
		local Clock = require("./Clock")
		Clock.Set(function() return 1000 end)
		local At = Clock.Now()
--]=]

local CENTURY = 100 * 31556952

local function Real(): number
	return os.time()
end

local Source: () -> number = Real

local function Vet(Reads: () -> number)
	local Ok, Value = pcall(Reads)
	assert(
		Ok and type(Value) == "number" and Value == Value and Value ~= math.huge and Value ~= -math.huge,
		"the clock given to Ledger.UseClock has to give back a number of seconds"
	)

	local Held = Real()
	if math.abs(Value - Held) <= CENTURY then
		return
	end

	warn(
		`Ledger: the clock you gave reads {Value} and the real one reads {Held}. Ledger counts in seconds since 1970, so give it seconds`
	)
end

local function Set(Reads: (() -> number)?)
	if Reads ~= nil then
		Vet(Reads)
	end
	Source = Reads or Real
end

local function Now(): number
	return Source()
end

return table.freeze({
	Set = Set,
	Now = Now
})
