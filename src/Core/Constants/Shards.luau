--!strict
--!optimize 2

--[=[
	Shards: How a tally is spread over keys.

	A tally lives on a fixed number of keys so servers do not queue behind one another. PART separates
	the tally name from the shard number in a key, and FIELD is where the running total is kept.

	Return type: A table with SHARDS, PART and FIELD.
	Example usage:
		local Shards = require("./Shards")
		local Key = `{Name}{Shards.PART}{Index}`
--]=]

return table.freeze({
	SHARDS = 16,
	PART = "#",
	FIELD = "_Tally",
})
