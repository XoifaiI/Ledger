--!strict

--[=[

	Sizes: The default room sizes in characters, and the state cap in json bytes.

	TIMED_ROOM holds writer entries and timed names, UNTIMED_ROOM untimed names, and CUT_NAMES is how
	many cut names a key keeps. STATE_CAP is the largest state.

	Return type: A frozen table of the sizes.
	Example usage:
		local Room = Sizes.TIMED_ROOM
--]=]

return {
	TIMED_ROOM = 12288,
	UNTIMED_ROOM = 4096,
	CUT_NAMES = 8,
	STATE_CAP = 2 * 1024 * 1024,
}
