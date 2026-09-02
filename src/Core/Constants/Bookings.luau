--!strict
--!optimize 2

--[=[
	Bookings: Where a hold on units lives, in names.

	A hold is a MemoryStore item per key, holding every unexpired hold on that key and the stock the
	key last read for each field. MAP is the map those items live in, and CONFIRM_ID is the prefix
	the op that spends a hold carries, derived from the hold's name so a retry lands once.

	Return type: A table with MAP and CONFIRM_ID.
	Example usage:
		local Bookings = require("./Bookings")
		local Holds = Wrapper.New(Bookings.MAP, Turn, Hook)
--]=]

return table.freeze({
	MAP = "Ledger_Hold",
	CONFIRM_ID = "cf",
})
