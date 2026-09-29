--!strict

--[=[

	Windows: The times Ledger waits or keeps things for, in seconds, at their defaults.

	MINTED is how long a writer entry and a timed name are kept, and CUT how long a cut name is kept.
	SIGMA is the most a clock may be wrong. AHEAD is how far past the clock an op may be stamped before
	it waits, and HOLD how far a fit keeps an item stamped ahead. BREAKER is how long the calls to a
	map that keeps missing stop. SLOW is how long a listener may run before Ledger says so. ANSWER is
	how long a call waits for its fate before it answers Unresolved. SHED is how long a durable op may
	wait unsent before it answers Busy.

	Return type: A frozen table of the windows.
	Example usage:
		local Windows = require("./Windows")
		local Keep = Windows.MINTED
--]=]

local SIGMA = 30
local AHEAD = 2 * SIGMA

return table.freeze({
	MINTED = 180,
	CUT = 360,
	SIGMA = SIGMA,
	AHEAD = AHEAD,
	HOLD = AHEAD + 2 * SIGMA,
	BREAKER = 120,
	SLOW = 10,
	ANSWER = 30,
	SHED = 10,
})
