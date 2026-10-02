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
	marks an op is judged beside. ATTEMPTS is how many attempts a transaction makes, and OWED_FREE
	how many pinned records an owed commit verifies. OP_BYTES is the largest op a transaction leg
	carries, and LEVELS the most levels a touch counts. ITEM_MAX is the most one named item may
	take, and ROOMS_MAX the most every room a game sets may take together. SHARDS is how many shards
	a total has by default, and SHARDS_MAX the most it may have. TOTAL_NAME is the longest name a
	total may have. ITEM_ROOM is the most a MemoryStore item of Ledger's may take. HEADER is what a
	copy item takes besides its state. PARTS_MAX is the most parts a copy's state may be cut into.
	MAPS is how many maps each purpose spreads its items over. MONEY_LIMIT is one past the largest
	whole amount a double holds exactly. LEGS_MIN is the fewest legs a transaction has. DRAWS is how
	many names a call with no name draws. PRINT_MASK keeps the 16 bits of a print. COPY_MISSES is how
	many part misses in a row make a follower a taker. PACE_SHARD is the share of a key's write
	ceiling a shard's writer aims below, and PACE_PART the share a part's writer aims below. GAP_FALL
	is the least a gap is multiplied by at one landing. SPLIT_MAX is the most parts a quantity has,
	and SPLIT_NAME the longest name a quantity may have. HOLDS_MAX is the most holds a part keeps.
	PROBES is how many parts a walk under a drawn name tries, and PROCEEDS_MAX the most money fields
	a quantity's takes pay into.

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
	ITEM_MAX = 84,
	ROOMS_MAX = 49152,
	SHARDS = 16,
	SHARDS_MAX = 64,
	TOTAL_NAME = 37,
	ITEM_ROOM = 32000,
	HEADER = 64,
	PARTS_MAX = 4,
	MAPS = 16,
	MONEY_LIMIT = 2 ^ 53,
	LEGS_MIN = 2,
	DRAWS = 2,
	PRINT_MASK = 0xFFFF,
	COPY_MISSES = 2,
	PACE_SHARD = 2,
	PACE_PART = 1,
	SPLIT_MAX = 64,
	SPLIT_NAME = 37,
	HOLDS_MAX = 256,
	PROBES = 3,
	PROCEEDS_MAX = 4,
	GAP_FALL = 0.5,
}
