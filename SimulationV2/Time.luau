--!strict
--!optimize 2

--[=[
	Time: The time that a run reads, in simulated seconds.

	A wait moves the clock and does not wait for anything, because every window Ledger holds is
	counted in days. The wait still gives up its turn. Ledger takes this through UseClock.

	Return type: A table with Read, Sleep, Bind, Advance and Restart.
	Example usage:
		Time.Advance(86400)
--]=]

local EPOCH = 1700000000

local Held = EPOCH

local Turn: any = nil

local function Bind(Driver: any)
	Turn = Driver
end

local function Read(): number
	return Held
end

local function Sleep(Seconds: number)
	Held += math.max(Seconds, 0)

	if Turn ~= nil then
		Turn:Wait()
		return
	end
	task.wait()
end

local function Advance(Seconds: number)
	assert(Seconds >= 0, "a simulated clock only moves forward")
	Held += Seconds
end

local function Restart()
	Held = EPOCH
	Turn = nil
end

return table.freeze({
	Read = Read,
	Sleep = Sleep,
	Bind = Bind,
	Advance = Advance,
	Restart = Restart,
})
