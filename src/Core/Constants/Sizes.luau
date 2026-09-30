--!strict

--[=[

	Sizes: Logic. The default room sizes in characters, and the state cap in json bytes.

	Spec: record 2.4 and 13.

	TIMED_ROOM holds writer entries and timed names, UNTIMED_ROOM untimed names, and CUT_NAMES is how
	many cut names a key keeps. WORK_ROOM holds marks and pinned records, at most MARK_CAP marks and
	OWED_CAP pinned records, each at most MARK_MAX. POST_CAP is the largest post diff of an exclusive
	mark. STATE_CAP is the largest state, and QUEUE_BYTES the most a session may hold queued.

	Return type: A table of the sizes.
	Example usage:
		local Room = Sizes.TIMED_ROOM
--]=]

return {
	TIMED_ROOM = 12288,
	UNTIMED_ROOM = 4096,
	CUT_NAMES = 8,
	WORK_ROOM = 8192,
	MARK_CAP = 16,
	OWED_CAP = 16,
	MARK_MAX = 512,
	POST_CAP = 4096,
	STATE_CAP = 2 * 1024 * 1024,
	QUEUE_BYTES = 1.5 * 1024 * 1024,
}
