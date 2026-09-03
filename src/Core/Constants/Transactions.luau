--!strict
--!optimize 2

--[=[
	Transactions: The shape of the transaction protocol, in numbers and names.

	How many keys one transaction may touch, and how many other stores this server keeps a handle to.
	The three states a marker can be in, and the four ways opening one can turn out. The cleanup list
	is spread over shards. Each key holds up to a limit, then the next part of that minute takes the
	rest. A reap pass is bounded by how many markers it looks at and takes off.

	SUFFIX is what a store's own name gains to make the name of the store its markers live in. The cap
	on a store name is the datastore cap less this.

	Asking for a lease answers one of four. Absent is a store with no map at all, where Unknown is a
	map that did not answer.

	Return type: A table with the caps, the three statuses, the four openings, the four lease answers, the names and the lease numbers. The types are Status, Opened and Claim.
	Example usage:
		local Transactions = require("./Transactions")
		if #Legs > Transactions.MAX_LEGS then Refuse() end
--]=]

export type Status = "Pending" | "Committed" | "Aborted"

export type Opened = "Created" | "Mismatch" | "Unwritten" | "Husk"

export type Claim = "Taken" | "Held" | "Unknown" | "Absent"

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
	SUFFIX = "_Tx",
	SHARDS = 32,
	ROLL_LIMIT = 256,
	PARTS = 64,

	REAP_LIMIT = 64,
	REAP_LOOKS = 16,
	REAP_PAGE = 50,
	REAP_FLOOR = 18,

	LEASE_MAP = "Ledger_Lease",
	LEASE_BUDGET = 8,

	TAKEN = "Taken" :: "Taken",
	HELD = "Held" :: "Held",
	UNKNOWN = "Unknown" :: "Unknown",
	ABSENT = "Absent" :: "Absent",
})
