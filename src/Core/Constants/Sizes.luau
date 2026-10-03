--!strict

--[=[
	Sizes: Logic. The record's rooms and caps, in characters of the book or json bytes.

	Each room has a default and the bounds a game may set it within. The least loss room is not here:
	Book.LossFloor gives it for the store's money fields. ITEM_MAX is the most one named item takes,
	and ROOMS_MAX the most every room a game sets may take together. The asserts hold the record's
	bound: at its largest, a key's book plus its state and a Reset's given state stays under the
	datastore's value cap, whatever the traffic.

	Return type: A table of the sizes.
	Example usage:
		local Room = Sizes.TIMED_ROOM
--]=]

local TIMED_ROOM = 12288
local UNTIMED_ROOM = 4096
local WORK_ROOM = 8192
local LOSS_ROOM = 4096
local CUT_NAMES = 8
local ITEM_MAX = 84
local ROOMS_MAX = 49152
local POST_CAP = 4096
local STATE_CAP = 2 * 1024 * 1024
local RESET_MAX = 1024 * 1024
local VALUE_CAP = 4194304
local BOOK_FIXED = 144
local GATE_MAX = 90
local POST_KEY = 8

assert(TIMED_ROOM + UNTIMED_ROOM + WORK_ROOM + LOSS_ROOM + CUT_NAMES * ITEM_MAX <= ROOMS_MAX, "Sizes: the default rooms must fit ROOMS_MAX (record 2.4)")
assert(STATE_CAP + RESET_MAX + BOOK_FIXED + ROOMS_MAX + GATE_MAX + POST_CAP + POST_KEY < VALUE_CAP, "Sizes: the largest book, state and given state must fit the value cap (record 2.4)")

return {
	TIMED_ROOM = TIMED_ROOM,
	UNTIMED_ROOM = UNTIMED_ROOM,
	CUT_NAMES = CUT_NAMES,
	WORK_ROOM = WORK_ROOM,
	MARK_CAP = 16,
	OWED_CAP = 16,
	MARK_MAX = 512,
	POST_CAP = POST_CAP,
	STATE_CAP = STATE_CAP,
	LOSS_ROOM = LOSS_ROOM,
	RESET_MAX = RESET_MAX,
	ITEM_MAX = ITEM_MAX,
	ROOMS_MAX = ROOMS_MAX,
	TIMED_ROOM_MIN = 2048,
	TIMED_ROOM_MAX = 32768,
	UNTIMED_ROOM_MIN = 0,
	UNTIMED_ROOM_MAX = 16384,
	WORK_ROOM_MIN = 4096,
	WORK_ROOM_MAX = 16384,
	LOSS_ROOM_MAX = 16384,
	CUT_NAMES_MIN = 2,
	CUT_NAMES_MAX = 64,
}
