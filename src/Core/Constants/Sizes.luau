--!strict

--[=[

	Sizes: Logic. The default room sizes in characters, and the state cap in json bytes.

	Spec: record 2.4 and 13.

	TIMED_ROOM holds writer entries and timed names, UNTIMED_ROOM untimed names, and CUT_NAMES is how
	many cut names a key keeps. WORK_ROOM holds marks and pinned records, at most MARK_CAP marks and
	OWED_CAP pinned records, each at most MARK_MAX. POST_CAP is the largest post diff of an exclusive
	mark. STATE_CAP is the largest state, and QUEUE_BYTES the most a session may hold queued. LOSS_ROOM
	holds a key's cut events and fold slots, and RESET_MAX is the largest state a Reset may be given.
	The MIN and MAX of each room are the bounds a game may set it within. LOSS_ROOM_MIN is not here:
	Book.LossFloor gives it for the store's money fields. REQUEST_SHARE is the share of the timed
	room one request may fill with new timed bytes. KB is the bytes in a kilobyte, and KEY_CEILING
	the kilobytes a key may take in writes each minute.

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
	LOSS_ROOM = 4096,
	RESET_MAX = 1024 * 1024,
	TIMED_ROOM_MIN = 2048,
	TIMED_ROOM_MAX = 32768,
	UNTIMED_ROOM_MIN = 0,
	UNTIMED_ROOM_MAX = 16384,
	WORK_ROOM_MIN = 4096,
	WORK_ROOM_MAX = 16384,
	LOSS_ROOM_MAX = 16384,
	CUT_NAMES_MIN = 2,
	CUT_NAMES_MAX = 64,
	REQUEST_SHARE = 4,
	KB = 1024,
	KEY_CEILING = 4096,
}
