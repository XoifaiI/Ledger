--!strict

--[=[

	Windows: Logic. The default times, in seconds.

	Spec: record 13; transaction 11.

	MINTED and CUT are how long entries and cut names are kept. SIGMA is the most a clock may be
	wrong. AHEAD is how far past the clock an op may be stamped, and HOLD how far ahead Fit keeps an
	item. BREAKER is how long a failing map rests. ANSWER is how long an op waits for its fate, and
	SHED how long a durable op waits unsent. BACKOFF is the longest wait between tries. SAVE is how
	often a session pushes its queued ops, and IDLE how often a session with none reads its key. BEAT
	is how often the heartbeat asks the sessions, and CLOSE the most a closing server waits. CEILING
	is the longest window a game may give an op kind. SETTLE is how old an undecided mark is before
	any writer may fence it, and PINNED how old a pinned record is before a touch ends it. LAG is the
	most a read lags once faults stop, DELAY the most a request takes, and STEP the wait a touch adds
	for each level below the top. ORPHAN is how old an item is before a read of its other key that
	shows it gone ends it.

	Return type: A table of the windows.
	Example usage:
		local Keep = Windows.MINTED
--]=]

local SIGMA = 30
local AHEAD = 2 * SIGMA
local LAG = 15
local DELAY = 15

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
	CEILING = 30 * 86400,
	SETTLE = 10,
	PINNED = 90,
	LAG = LAG,
	DELAY = DELAY,
	STEP = LAG + 2 * SIGMA + 3 * DELAY,
	ORPHAN = 86400,
}
