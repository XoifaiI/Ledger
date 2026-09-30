--!strict

--[=[

	Windows: The default times, in seconds.

	MINTED and CUT are how long entries and cut names are kept. SIGMA is the most a clock may be
	wrong. AHEAD is how far past the clock an op may be stamped, and HOLD how far ahead Fit keeps an
	item. BREAKER is how long a failing map rests. ANSWER is how long an op waits for its fate, and
	SHED how long a durable op waits unsent. BACKOFF is the longest wait between tries. SAVE is how
	often a session pushes its queued ops, and IDLE how often a session with none reads its key. BEAT
	is how often the heartbeat asks the sessions, and CLOSE the most a closing server waits.

	Return type: A table of the windows.
	Example usage:
		local Keep = Windows.MINTED
--]=]

local SIGMA = 30
local AHEAD = 2 * SIGMA

return {
	MINTED = 180,
	CUT = 360,
	SIGMA = SIGMA,
	AHEAD = AHEAD,
	HOLD = AHEAD + 2 * SIGMA,
	BREAKER = 120,
	ANSWER = 30,
	SHED = 10,
	BACKOFF = 30,
	SAVE = 30,
	IDLE = 120,
	BEAT = 1,
	CLOSE = 25,
}
