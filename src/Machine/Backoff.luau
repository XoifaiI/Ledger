--!strict
--!optimize 2

--[=[

	Backoff: Plumbing. The wait before the next try: 1 second, doubling, up to Windows.BACKOFF.

	Return type: A function that gives back the wait in seconds.
	Example usage:
		task.wait(Backoff(Tries))
--]=]

local Windows = require("../Core/Constants/Windows")

local function Backoff(Tries: number): number
	return math.min(2 ^ (Tries - 1), Windows.BACKOFF)
end

return Backoff
