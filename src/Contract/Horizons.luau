--!strict
--!optimize 2

--[=[
	Horizons: Every window that Ledger keeps something for, in one place.

	Ledger holds nothing without a limit. A window bounds each set that Ledger keeps, and the age of
	the key does not.
	The windows must agree with each other. A tomb must outlast the last time a transfer is sent
	again, and a reservation must run out before a transfer does. The asserts below hold these rules,
	so a reader does not have to find them.

	Return type: A table of the windows in seconds, and the caps on one pass.
	Example usage:
		local Horizons = require("../Contract/Horizons")
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

local PASS_LIMIT = 32

assert(REDRIVE + EXPIRE_MARGIN == TOMB, "a tomb has to outlast the last redelivery of a transfer, or money could be sent to a key that has already stopped turning it away")
assert(TOMB < PRUNE, "a delivery id has to outlive the tomb of the key it was delivered to, or a refund could pay twice")
assert(BOOK + BOOK_MARGIN < REDRIVE, "a reservation has to run out before a transfer does, or stock would be held longer than money")
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

	PASS_LIMIT = PASS_LIMIT,
})
