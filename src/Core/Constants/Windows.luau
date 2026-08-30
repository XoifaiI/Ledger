--!strict
--!optimize 2

--[=[

	Windows: Every window Ledger keeps something for.

	Windows in seconds, the longest hold a game may ask for, and the cap on one pass of background
	work. Anything that follows from another window is derived here, and asserts hold the order they
	have to keep.

	Return type: A table of the windows in seconds, the longest hold a game may ask for, and the cap on one pass.
	Example usage:
		local Windows = require("./Windows")
		if Now - At > Windows.PRUNE then Drop() end
--]=]

local DAY = 86400
local HOUR = 3600
local MINUTE = 60

local PRUNE = 30 * DAY
local REDRIVE = 7 * DAY
local EXPIRE_MARGIN = DAY
local BOOK = 15 * MINUTE
local BOOK_MARGIN = 10 * MINUTE
local REAP = HOUR
local REAP_GRACE = 5 * MINUTE
local BUCKET = MINUTE
local LEG = 30
local POLL = 5
local SWEEP = MINUTE
local AUTOSAVE = 30

local TOMB = REDRIVE + EXPIRE_MARGIN
local ONCE_MARGIN = REDRIVE
local STUCK = PRUNE
local HOLD_CAP = PRUNE - BOOK_MARGIN
local ONCE_FLOOR = PRUNE - ONCE_MARGIN
local TX = LEG * 2

local PASS_LIMIT = 32

assert(TOMB < PRUNE, "a delivery id has to outlive the tomb of the key it was delivered to, or a refund could pay twice")
assert(BOOK + BOOK_MARGIN < REDRIVE, "a reservation has to run out before a transfer does, or stock would be held longer than money")
assert(HOLD_CAP > BOOK, "a game has to be able to ask for a hold at least as long as the one Ledger uses by default")
assert(REAP_GRACE < REAP, "a marker that is already finished goes on the shorter window, and one that is still being decided goes on the longer one")
assert(
	STUCK > REAP,
	"a marker nothing can judge has to outlive the window an ordinary one is judged in by a wide margin, or a pass would give up on one that a later pass could still have read properly"
)
assert(ONCE_FLOOR > 0 and ONCE_FLOOR < PRUNE, "a caller has to be able to stamp a name in the past at all, so the margin cannot take the whole window or none of it")
assert(
	BOOK_MARGIN > 0 and BOOK_MARGIN < BOOK,
	"a reservation is held past its hold so a slow hand over cannot race the recovery that gives its units back, and that wait is added to the hold a game asked for, so it has to be the smaller of the two"
)
assert(POLL < TX, "a session polling for a parked leg has to look more than once before it gives up on the transaction")
assert(SWEEP < REAP, "the sweep has to run more often than the window it reaps markers on, or a marker would wait on the pass rather than on its horizon")
assert(
	BUCKET < REAP_GRACE,
	"a cleanup list key has to stop being written to before a reaper may judge it, or a name added late lands on a key the reaper has already emptied and its marker is left with nothing pointing at it"
)

return table.freeze({
	PRUNE = PRUNE,
	REDRIVE = REDRIVE,
	EXPIRE_MARGIN = EXPIRE_MARGIN,
	BOOK = BOOK,
	BOOK_MARGIN = BOOK_MARGIN,
	REAP = REAP,
	REAP_GRACE = REAP_GRACE,
	BUCKET = BUCKET,
	LEG = LEG,
	POLL = POLL,
	SWEEP = SWEEP,
	AUTOSAVE = AUTOSAVE,

	TOMB = TOMB,
	ONCE_MARGIN = ONCE_MARGIN,
	STUCK = STUCK,
	HOLD_CAP = HOLD_CAP,
	ONCE_FLOOR = ONCE_FLOOR,
	TX = TX,

	PASS_LIMIT = PASS_LIMIT,
})
