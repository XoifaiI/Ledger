--!strict
--!optimize 2

--[=[
	Datastore: The limits a real datastore keeps, which the mock keeps as well.

	How long a name and a key may be, how many versions of a key are kept, how many rows a page hands
	back, and the request budget: a base allowance plus a share per player, refilled over a window.
	The byte lanes are how much one key may be read from or written to in that same window.

	Return type: A table with the caps, the queue limits, the byte lanes and READING and WRITING.
	Example usage:
		local Datastore = require("./Datastore")
		if #Key > Datastore.MAX_KEY then Refuse() end
--]=]

return table.freeze({
	MAX_NAME = 50,
	MAX_SCOPE = 50,
	MAX_KEY = 50,
	KEEP_VERSIONS = 30,
	PAGE_LIMIT = 100,
	CONFLICT_LIMIT = 32,

	REFILL_WINDOW = 60,
	QUEUE_LIMIT = 30,
	QUEUE_STEP = 0.05,

	READING = "r",
	WRITING = "w",
	READ_BYTES = 25 * 1024 * 1024,
	WRITE_BYTES = 4 * 1024 * 1024,

	THROTTLED = "DataStore request dropped, the queue is full and this server is out of budget",
})
