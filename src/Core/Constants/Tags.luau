--!strict
--!optimize 2

--[=[
	Tags: The prefixes an applied name is stored under, and the answers to asking about one.

	A name is kept under the tag of what it was, so a transfer, a transaction, a Once name, a sent
	hold and a grant cannot collide. MEANT separates the time of a write from the mark of what the
	name meant. Recalling a name answers Unseen, Same or Other.

	Return type: A table with the five tags, MEANT and the three recalls. The type is Recalled.
	Example usage:
		local Tags = require("./Tags")
		local Key = `{Tags.ONCE}{Id}`
--]=]

export type Recalled = "Unseen" | "Same" | "Other"

return table.freeze({
	TRANSFER = "t:",
	TX = "x:",
	ONCE = "o:",
	SENT = "s:",
	GRANT = "g:",

	MEANT = "#",

	UNSEEN = "Unseen" :: Recalled,
	SAME = "Same" :: Recalled,
	OTHER = "Other" :: Recalled,
})
