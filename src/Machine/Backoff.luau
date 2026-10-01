--!strict
--!optimize 2

--[=[

	Backoff: Plumbing. Every wait Ledger draws or doubles.

	Retry gives the wait before the next try. It starts at First, 1 second when not given, and doubles
	with each try up to Most, Windows.BACKOFF when not given. Jitter gives a random wait from 0 to
	Most.

	Return type: A table with Retry and Jitter.
	Example usage:
		task.wait(Backoff.Retry(Tries))
--]=]

local Windows = require("../Core/Constants/Windows")

local Backoff = {}

function Backoff.Retry(Tries: number, First: number?, Most: number?): number
	return math.min((First or 1) * 2 ^ (Tries - 1), Most or Windows.BACKOFF)
end

function Backoff.Jitter(Most: number): number
	return math.random() * Most
end

return Backoff
