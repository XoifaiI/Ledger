--!strict
--!optimize 2

--[=[
	Sessions: The shape of a live session's autosave, in numbers and names.

	An idle session reads its key from the datastore every so many ticks whatever the MemoryStore
	says, checks the flag on every other tick, and stops checking for a window after a run of misses.
	FLAG_MAP is the MemoryStore map a write flags the key in.

	Return type: A table with IDLE_EVERY, IDLE_MISSES and FLAG_MAP.
	Example usage:
		local Sessions = require("./Sessions")
		if Ticks % Sessions.IDLE_EVERY == 0 then Read() end
--]=]

return table.freeze({
	IDLE_EVERY = 4,
	IDLE_MISSES = 3,

	FLAG_MAP = "Ledger_Dirty",
})
