--!strict
--!optimize 2

--[=[
	Kinds: Every op kind Ledger writes, and the prefix each of their ids carries.

	A kind Ledger owns starts with two underscores, which a game may not use. An id prefix keeps one
	leg of a protocol apart from the others under the same name. A reserve and a settle for one
	transfer are two ids rather than one. ENVELOPE is the format of the record itself.

	Return type: A table with ENVELOPE, RESET, the transfer and tally kinds, and the id prefixes.
	Example usage:
		local Kinds = require("./Kinds")
		local Id = `{Kinds.RESERVE_ID}:{Tid}`
--]=]

return table.freeze({

	ENVELOPE = 1,

	RESET = "__Reset",
	BUMP = "__Bump",

	RESERVE = "__TransferReserve",
	DELIVER = "__TransferDeliver",
	SETTLE = "__TransferSettle",
	PRUNE = "__TransferPrune",
	EXPIRE = "__TransferExpire",

	RESERVE_ID = "res",
	DELIVER_ID = "del",
	SETTLE_ID = "set",
	PRUNE_ID = "prn",
	EXPIRE_ID = "exp",
})
