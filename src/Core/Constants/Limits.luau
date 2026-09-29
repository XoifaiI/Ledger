--!strict

--[=[

	Limits: The hard bounds Ledger holds values to.

	STAMP_MAX is the largest stamp, 2^40 seconds; a clock past it stamps nothing. WRITES_MAX is the
	write count at which a key is worn and takes no more writes. FATES_MAX is the most fates that are
	not took a writer's entry keeps. DEPTH_MAX is how deep a stored value may nest. MISSES is how many
	MemoryStore calls in a row may miss before the calls to that map stop for a while. SEQ_MAX is the
	most ops one writer numbers. TRIES is how many requests in a row may fail before an op answers
	Unresolved. QUEUE is the most ops a writer holds. COUNTERS is how many keys hand out server
	numbers.

	Return type: A frozen table of the bounds.
	Example usage:
		local Limits = require("./Limits")
		if Stamp > Limits.STAMP_MAX then return end
--]=]

return table.freeze({
	STAMP_MAX = 2 ^ 40,
	WRITES_MAX = 2 ^ 53 - 1,
	FATES_MAX = 64,
	DEPTH_MAX = 64,
	MISSES = 3,
	SEQ_MAX = 32767,
	TRIES = 3,
	QUEUE = 4096,
	COUNTERS = 16,
})
