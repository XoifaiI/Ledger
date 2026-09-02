--!strict
--!optimize 2

--[=[
	MemoryStore: The limits a real MemoryStore keeps, which the mock keeps as well.

	How long a map name and a key may be, the lowest byte a key may hold, how many bytes an item is
	as json, how long an item may live, and the request units: a base allowance plus a share per user
	in the whole experience, refilled over the same window as the request budget. An update costs at
	least two units and every other call costs one. Each was measured against the live service.

	Return type: A table with the caps, the unit costs, the quota and THROTTLED.
	Example usage:
		local MemoryStore = require("./MemoryStore")
		if #Key > MemoryStore.MAX_KEY then Refuse() end
--]=]

return table.freeze({
	MAX_NAME = 128,
	MAX_KEY = 128,
	KEY_FLOOR = 32,
	MAX_ITEM = 32 * 1024,
	MAX_EXPIRY = 3888000,

	UNIT = 1,
	UPDATE_UNITS = 2,

	QUOTA_BASE = 1000,
	QUOTA_PER_USER = 120,

	THROTTLED = "MemoryStore request dropped, this experience is out of request units",
})
