--!strict
--!optimize 2

--[=[
	Backoff: Plumbing. Every wait Ledger draws or doubles.

	Retry doubles from First, 1 second by default, up to Most, BACKOFF by default. Jitter is
	uniform from 0 to Most.

	Return type: A table with Retry and Jitter.
	Example usage:
		task.wait(Backoff.Retry(Tries))
--]=]

local BACKOFF = 30

local Backoff = {}

function Backoff.Retry(Tries: number, First: number?, Most: number?): number
	return math.min((First or 1) * 2 ^ (Tries - 1), Most or BACKOFF)
end

function Backoff.Jitter(Most: number): number
	return math.random() * Most
end

return Backoff
