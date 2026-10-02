--!strict

--[=[

	Windows: Logic. The default times, in seconds.

	Spec: record 13; transaction 11.

	MINTED and CUT are how long entries and cut names are kept. SIGMA is the most a clock may be
	wrong. AHEAD is how far past the clock an op may be stamped, and HOLD how far ahead Fit keeps an
	item. BREAKER is how long a failing map rests. ANSWER is how long an op waits for its fate, and
	SHED how long a durable op waits unsent. BACKOFF is the longest wait between tries. SAVE is how
	often a session pushes its queued ops, and IDLE how often a session with none reads its key.
	BEAT is how often the heartbeat asks the sessions, and CLOSE the most a closing server waits.
	CEILING is the longest window a game may give an op kind. SETTLE is how old an undecided mark is
	before any writer may fence it. PINNED is how old a pinned record is before a touch ends it. LAG
	is the most a read lags once faults stop, and DELAY the most a request takes. STEP is the wait a
	touch adds for each level below the top. ORPHAN is how old an item is before a read of its other
	key that shows it gone ends it. KEEP_NAMED is how long a cut's event stays whole, and FOLD_SPAN
	the period of a fold slot, which lives two of them. REMOVE_SEND is how long after rt a sealer
	may send its removal. REMOVE_LATE is the most a lost removal may land late. It is the one
	platform bound a safety property rests on. SEAL_AGE is the age of rt past which a seal is left
	over. It is REMOVE_SEND, REMOVE_LATE and two clock errors, plus one second. GAP_MIN and GAP_MAX
	bound the gap a paced writer keeps between sends, and it starts at GAP_MAX. RETRY_GAP is its
	first wait after a failed request, doubling up to RETRY_MAX. PRUNE_AGE is how old an entry on a
	paced key is before a read of it sends a tidy. REFRESH is how often a summary's holder refreshes
	it. JITTER is the most a taker adds at random to its lapse. LEASE is how long a holder means to
	hold: REFRESH, one request and two clock errors. SUMMARY is a summary item's expiry. DOWN is how
	long a server answers a total from its own pairs while MemoryStore fails. HOLDING is how long a
	holder keeps refreshing after its own last read of the total. MAX_AGE is how old a total may be
	when a game's Total gives no MaxAge. MINUTE and DAY are what they say. SKEW is the most two
	clocks differ. LAPSE is how far past a holder's lease a reader waits before it takes over,
	before its jitter. KEEP_NAMED_MIN and KEEP_NAMED_MAX bound the KeepNamed a game may set. REPUSH
	is how old a holder's last push of a copy is before it sends the state again. HOLD_MAX is the
	longest a hold on a part may last. HOLD_SLACK is how far past its end a part's clock must read
	before it expires the hold. VIEW_AGE is how young a server's view of every part must be to
	answer Busy. TICK is how often a follower first reads a copy's header, doubling while the copy
	does not move up to TICK_MAX. CHECK is how often a copy's holder reads the key, and COPY a copy
	item's expiry. FOLLOW_EVERY is how often a follower reads the key itself while the copy cannot
	serve it.

	Return type: A table of the windows.
	Example usage:
		local Keep = Windows.MINTED
--]=]

local SIGMA = 30
local AHEAD = 2 * SIGMA
local LAG = 15
local DELAY = 15
local REMOVE_SEND = 60
local REMOVE_LATE = 3600
local REFRESH = 15
local DAY = 86400
local COPY = 3600

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
	KEEP_NAMED = 7 * DAY,
	FOLD_SPAN = 15 * 86400,
	REMOVE_SEND = REMOVE_SEND,
	REMOVE_LATE = REMOVE_LATE,
	SEAL_AGE = REMOVE_SEND + REMOVE_LATE + 2 * SIGMA + 1,
	GAP_MIN = 1,
	GAP_MAX = 60,
	RETRY_GAP = 2,
	RETRY_MAX = 16,
	PRUNE_AGE = 86400,
	REFRESH = REFRESH,
	JITTER = 30,
	LEASE = REFRESH + DELAY + 2 * SIGMA,
	SUMMARY = 3600,
	DOWN = 60,
	HOLDING = 600,
	MAX_AGE = 60,
	TICK = 30,
	TICK_MAX = 240,
	CHECK = 30,
	COPY = COPY,
	FOLLOW_EVERY = 60,
	MINUTE = 60,
	DAY = DAY,
	SKEW = 2 * SIGMA,
	LAPSE = 2 * SIGMA + DELAY,
	KEEP_NAMED_MIN = 7 * DAY,
	KEEP_NAMED_MAX = 30 * DAY,
	REPUSH = COPY / 2,
	HOLD_MAX = 15 * 60,
	HOLD_SLACK = 2 * SIGMA,
	VIEW_AGE = 30,
}
