--!strict
--!optimize 2

--[=[
	Bookings: Where a hold on units lives, in names.

	A hold is a MemoryStore item per key. It holds every unexpired hold on that key, and the stock the
	key last read for each field. MAP is the map those items live in. CONFIRM_ID is the prefix the op
	that spends a hold carries. That id comes from the hold's name, so a retry lands once.

	Taking a hold answers one of five, and letting one go answers one of four. Absent is a store with
	no map at all, where Unknown is a map that did not answer.

	Return type: A table with MAP, CONFIRM_ID and those answers. The types are Reserved and Dropped.
	Example usage:
		local Bookings = require("./Bookings")
		local Holds = Wrapper.New(Bookings.MAP, Turn, Hook)
--]=]

export type Reserved = "Taken" | "Cold" | "Refused" | "Full" | "Unknown"

export type Dropped = "Dropped" | "Missing" | "Unknown" | "Absent"

return table.freeze({
	MAP = "Ledger_Hold",
	CONFIRM_ID = "cf",

	TAKEN = "Taken" :: "Taken",
	COLD = "Cold" :: "Cold",
	REFUSED = "Refused" :: "Refused",
	FULL = "Full" :: "Full",
	UNKNOWN = "Unknown" :: "Unknown",

	DROPPED = "Dropped" :: "Dropped",
	MISSING = "Missing" :: "Missing",
	ABSENT = "Absent" :: "Absent",
})
