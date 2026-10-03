--!strict

--[=[
	Windows: Logic. The times, in seconds, that more than one feature reads.

	SIGMA, LAG, DELAY and LATE bound clock error, read lag, request time and how late a retry comes
	once faults stop. They and every window built from them serve liveness only. REMOVE_LATE is the
	one platform bound a safety property rests on: a lost removal never lands more than that late.
	SEAL_AGE is REMOVE_SEND, REMOVE_LATE and two clock errors, plus one second. The asserts hold the
	relations between the windows. A constant only one feature reads lives in that feature's module.

	Return type: A table of the windows.
	Example usage:
		local Keep = Windows.MINTED
--]=]

local SIGMA = 30
local AHEAD = 2 * SIGMA
local LAG = 15
local DELAY = 15
local LATE = 60
local REMOVE_SEND = 60
local REMOVE_LATE = 3600
local REFRESH = 15
local DAY = 86400
local MINTED = 180
local CEILING = 30 * 86400
local ORPHAN = 86400
local FOLD_SPAN = 15 * 86400
local KEEP_NAMED = 7 * DAY
local KEEP_NAMED_MIN = 7 * DAY
local KEEP_NAMED_MAX = 30 * DAY

assert(MINTED > LATE + DELAY + 2 * SIGMA, "Windows: MINTED must pass LATE + DELAY + 2 * SIGMA (record 13)")
assert(ORPHAN > MINTED + 2 * SIGMA, "Windows: ORPHAN must pass MINTED + 2 * SIGMA (transaction 11)")
assert(ORPHAN < CEILING - 2 * SIGMA, "Windows: ORPHAN must stay under CEILING - 2 * SIGMA (transaction 11)")
assert(FOLD_SPAN * 2 == CEILING, "Windows: two fold periods must make CEILING (cuts 5)")
assert(KEEP_NAMED >= KEEP_NAMED_MIN and KEEP_NAMED <= KEEP_NAMED_MAX, "Windows: KEEP_NAMED must lie within its bounds (cuts 13)")
assert(KEEP_NAMED_MAX <= CEILING, "Windows: KEEP_NAMED_MAX must not pass CEILING (cuts 13)")

return {
	MINTED = MINTED,
	CUT = 360,
	SIGMA = SIGMA,
	AHEAD = AHEAD,
	HOLD = AHEAD + 2 * SIGMA,
	ANSWER = 30,
	CEILING = CEILING,
	SETTLE = 10,
	LAG = LAG,
	DELAY = DELAY,
	ORPHAN = ORPHAN,
	KEEP_NAMED = KEEP_NAMED,
	KEEP_NAMED_MIN = KEEP_NAMED_MIN,
	KEEP_NAMED_MAX = KEEP_NAMED_MAX,
	FOLD_SPAN = FOLD_SPAN,
	REMOVE_SEND = REMOVE_SEND,
	REMOVE_LATE = REMOVE_LATE,
	SEAL_AGE = REMOVE_SEND + REMOVE_LATE + 2 * SIGMA + 1,
	REFRESH = REFRESH,
	JITTER = 30,
	LEASE = REFRESH + DELAY + 2 * SIGMA,
	LAPSE = 2 * SIGMA + DELAY,
	SKEW = 2 * SIGMA,
	DAY = DAY,
}
