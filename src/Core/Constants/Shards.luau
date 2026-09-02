--!strict
--!optimize 2

--[=[
	Shards: How a tally is spread over keys.

	A tally lives on a fixed number of keys so servers do not queue behind one another. PART separates
	the tally name from the shard number in a key, FIELD is where the running total is kept, and MAP
	is the MemoryStore map a summed total is cached in.

	Return type: A table with SHARDS, PART, FIELD and MAP.
	Example usage:
		local Shards = require("./Shards")
		local Key = `{Name}{Shards.PART}{Index}`
--]=]

return table.freeze({
	SHARDS = 16,
	PART = "#",
	FIELD = "_Tally",
	MAP = "Ledger_Tally",
})
