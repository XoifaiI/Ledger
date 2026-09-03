--!strict
--!optimize 2

--[=[
	MemoryStore: The limits a real MemoryStore keeps, which the mock keeps as well.

	How long a map name and a key may be, and the lowest byte a key may hold. How many bytes an item
	is as json, and how long it may live. The request units are a base allowance plus a share per
	user, refilled over the same window as the request budget. An update costs at least two units and
	every other call costs one. One map has a ceiling of its own as well. A map over it is throttled
	however much the experience has left.

	A memory quota sits beside the request one, again a base plus a share per user. A write that grows
	the experience past it is refused. A read is not.

	OVERHEAD is what the fake charges for one stored item. It is the one estimate here rather than a
	limit. Roblox does not publish the accounting, and it measured at about twice the json. The rest
	come from the live service or the limits page.

	Return type: A table with the caps, the unit costs, the quotas, THROTTLED and FULL.
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
	QUOTA_MAP = 100000,

	MEMORY_BASE = 64 * 1024,
	MEMORY_PER_USER = 1.2 * 1024,
	MEMORY_OVERHEAD = 2,

	THROTTLED = "MemoryStore request dropped, this experience is out of request units",
	FULL = "MemoryStore write refused, this experience is out of memory",
})
