--!strict
--!optimize 2

--[=[
	Transactions: The shape of the transaction protocol, in numbers and names.

	How many keys one transaction may touch and how many other stores this server keeps a handle to.
	The three states a marker can be in and the four ways opening one can turn out. The cleanup list
	is spread over shards, each key holding up to a limit before the next part of that minute takes
	the rest, and a reap pass is bounded by how many markers it looks at and takes off.

	Return type: A table with the caps, the three statuses and the four openings. The types are Status and Opened.
	Example usage:
		local Transactions = require("./Transactions")
		if #Legs > Transactions.MAX_LEGS then Refuse() end
--]=]

export type Status = "Pending" | "Committed" | "Aborted"

export type Opened = "Created" | "Mismatch" | "Unwritten" | "Husk"

return table.freeze({
	MAX_LEGS = 4,
	MAX_HOMES = 64,
	PASSES = 3,

	PENDING = "Pending" :: Status,
	COMMITTED = "Committed" :: Status,
	ABORTED = "Aborted" :: Status,

	CREATED = "Created" :: Opened,
	MISMATCH = "Mismatch" :: Opened,
	UNWRITTEN = "Unwritten" :: Opened,
	HUSK = "Husk" :: Opened,

	RESERVED = "__",
	SHARDS = 32,
	ROLL_LIMIT = 256,
	PARTS = 64,

	REAP_LIMIT = 64,
	REAP_LOOKS = 16,
	REAP_PAGE = 64,
	REAP_FLOOR = 18,
})
