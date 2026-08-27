--!strict
--!optimize 2

--[=[
	Horizons: Every window that Ledger keeps something for, in one place.

	Ledger holds nothing without a limit. A window bounds each set that Ledger keeps, and the age of
	the key does not.
	The windows must agree with each other. A tomb must outlast the last time a transfer is sent
	again, and a reservation must run out before a transfer does. The asserts below hold these rules,
	so a reader does not have to find them.

	Return type: A table of the windows in seconds, the longest hold a game may ask for, and the caps on one pass.
	Example usage:
		local Horizons = require("./Horizons")
		if Now - At > Horizons.PRUNE then Drop() end
--]=]

local DAY = 86400

local PRUNE = 30 * DAY
local TOMB = 8 * DAY
local REDRIVE = 7 * DAY
local EXPIRE_MARGIN = DAY
local BOOK = 15 * 60
local BOOK_MARGIN = 10 * 60
local REAP = 3600
local REAP_GRACE = 300

local ONCE_MARGIN = REDRIVE
local STUCK = PRUNE

local HOLD_CAP = PRUNE - BOOK_MARGIN
local ONCE_FLOOR = PRUNE - ONCE_MARGIN

local PASS_LIMIT = 32

assert(REDRIVE + EXPIRE_MARGIN == TOMB, "a tomb has to outlast the last redelivery of a transfer, or money could be sent to a key that has already stopped turning it away")
assert(TOMB < PRUNE, "a delivery id has to outlive the tomb of the key it was delivered to, or a refund could pay twice")
assert(BOOK + BOOK_MARGIN < REDRIVE, "a reservation has to run out before a transfer does, or stock would be held longer than money")
assert(HOLD_CAP > BOOK, "a game has to be able to ask for a hold at least as long as the one Ledger uses by default")
assert(REAP_GRACE < REAP, "a marker that is already finished goes on the shorter window, and one that is still being decided goes on the longer one")
assert(
	ONCE_MARGIN >= REDRIVE,
	"a name a caller stamps in the past has to go on turning a retry away for at least as long as a transfer can still be sent again, or the retry the name exists to stop would land a second time"
)
assert(
	STUCK > REAP,
	"a marker nothing can judge has to outlive the window an ordinary one is judged in by a wide margin, or a pass would give up on one that a later pass could still have read properly"
)
assert(ONCE_FLOOR > 0 and ONCE_FLOOR < PRUNE, "a caller has to be able to stamp a name in the past at all, so the margin cannot take the whole window or none of it")
assert(
	BOOK_MARGIN > 0 and BOOK_MARGIN < BOOK,
	"a reservation is held past its hold so a slow hand over cannot race the recovery that gives its units back, and that wait is added to the hold a game asked for, so it has to be the smaller of the two"
)

return table.freeze({
	PRUNE = PRUNE,
	TOMB = TOMB,
	REDRIVE = REDRIVE,
	EXPIRE_MARGIN = EXPIRE_MARGIN,
	BOOK = BOOK,
	BOOK_MARGIN = BOOK_MARGIN,
	REAP = REAP,
	REAP_GRACE = REAP_GRACE,
	ONCE_MARGIN = ONCE_MARGIN,
	STUCK = STUCK,
	HOLD_CAP = HOLD_CAP,
	ONCE_FLOOR = ONCE_FLOOR,

	PASS_LIMIT = PASS_LIMIT,
})
