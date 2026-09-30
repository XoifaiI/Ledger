--!strict

--[=[

	Limits: Logic. The hard bounds.

	STAMP_MAX is the largest stamp. WRITES_MAX is the write count that wears a key out. FATES_MAX is
	how many fates other than took a writer entry keeps. DEPTH_MAX is how deep a value may nest.
	MISSES is how many MemoryStore misses open its breaker. SEQ_MAX is how many ops one writer
	numbers. TRIES is how many failed requests make an op answer Unresolved. QUEUE is how many ops a
	writer holds. COUNTERS is how many keys hand out server numbers. EPOCH is the unix time stamps
	count from. SHOWN_MAX is how many keys a server remembers showing, and SHOWN_BITS how many bits
	mark the keys it forgot. KINDS is how many numbers an op kind hashes to, and NAME_BYTES the
	longest name a game may give an op. WROTE_BITS is how many bits mark the keys a server number
	has written. MONEY_MAX is the most money fields a store declares. ORDER_MARKS is the most escrow
	marks an op is judged beside. ATTEMPTS is how many attempts a transaction makes, and OWED_FREE how
	many pinned records an owed commit verifies. OP_BYTES is the largest op a transaction leg carries,
	and LEVELS the most levels a touch counts.

	Return type: A table of the bounds.
	Example usage:
		if Stamp > Limits.STAMP_MAX then return end
--]=]

return {
	STAMP_MAX = 2 ^ 40,
	WRITES_MAX = 2 ^ 53 - 1,
	FATES_MAX = 64,
	DEPTH_MAX = 64,
	MISSES = 3,
	SEQ_MAX = 32767,
	TRIES = 3,
	QUEUE = 4096,
	COUNTERS = 16,
	EPOCH = 1767225600,
	SHOWN_MAX = 4096,
	SHOWN_BITS = 65536,
	KINDS = 32768,
	NAME_BYTES = 48,
	WROTE_BITS = 65536,
	MONEY_MAX = 64,
	ORDER_MARKS = 3,
	ATTEMPTS = 3,
	OWED_FREE = 8,
	OP_BYTES = 512,
	LEVELS = 16,
}
