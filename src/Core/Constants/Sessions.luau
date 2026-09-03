--!strict
--!optimize 2

--[=[
	Sessions: The shape of a live session's autosave, in numbers and names.

	An idle session reads its key from the datastore every so many ticks whatever the MemoryStore
	says, and checks the flag on every other tick. FLAG_MAP is the MemoryStore map a write flags the
	key in. A run of misses stops the checks for a window, which the MemoryStore wrapper owns.

	Return type: A table with IDLE_EVERY and FLAG_MAP.
	Example usage:
		local Sessions = require("./Sessions")
		if Ticks % Sessions.IDLE_EVERY == 0 then Read() end
--]=]

return table.freeze({
	IDLE_EVERY = 4,

	FLAG_MAP = "Ledger_Dirty",
})
