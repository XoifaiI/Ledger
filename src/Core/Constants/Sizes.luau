--!strict

--[=[

	Sizes: The default room sizes in characters, and the state cap in json bytes.

	TIMED_ROOM holds writer entries and timed names, UNTIMED_ROOM untimed names, and CUT_NAMES is how
	many cut names a key keeps. STATE_CAP is the largest state, and QUEUE_BYTES the most a session
	may hold queued.

	Return type: A table of the sizes.
	Example usage:
		local Room = Sizes.TIMED_ROOM
--]=]

return {
	TIMED_ROOM = 12288,
	UNTIMED_ROOM = 4096,
	CUT_NAMES = 8,
	STATE_CAP = 2 * 1024 * 1024,
	QUEUE_BYTES = 1.5 * 1024 * 1024,
}
