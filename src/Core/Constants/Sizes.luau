--!strict

--[=[

	Sizes: The rooms of a key's book and the cap on its state, in characters, at their defaults.

	TIMED_ROOM holds writer entries and timed names, UNTIMED_ROOM names a game chose with no time, and
	CUT_NAMES is how many cut names a key keeps. STATE_CAP is the most a game's state may take as json.
	A game may set each within the bounds record 2.4 gives.

	Return type: A frozen table of the sizes.
	Example usage:
		local Sizes = require("./Sizes")
		local Room = Sizes.TIMED_ROOM
--]=]

return table.freeze({
	TIMED_ROOM = 12288,
	UNTIMED_ROOM = 4096,
	CUT_NAMES = 8,
	STATE_CAP = 2 * 1024 * 1024,
})
