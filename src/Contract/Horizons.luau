--!strict
--!optimize 2

--[=[
	Horizons: Every window that Ledger keeps something for, in one place.

	Ledger holds nothing without a limit. Each set that it keeps is bounded by what happened inside
	one of these windows, and not by the age of the key.
	A tomb must outlast the last time that a transfer is sent again. If a tomb ran out first, a key
	would start to accept transfers while one was still on its way to it. That is checked below,
	and not left to a reader to notice.

	A reservation cannot be handed over once its hold runs out, and its units are not taken back until
	a margin after that. The margin covers how long a hand over can take, which is a few writes behind
	a queue and their retries, and not how long the hold is. It makes that race rare and does not make
	it impossible, so both sides also say so when they meet.

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
local BOOK_MARGIN = 5 * 60
local REAP = 3600

local PASS_LIMIT = 32

assert(
	REDRIVE + EXPIRE_MARGIN == TOMB,
	"a tomb has to outlast the last redelivery of a transfer, or money could be sent to a key that has already stopped turning it away"
)
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

	PASS_LIMIT = PASS_LIMIT
})
