--!strict
--!optimize 2

--[=[
	Tagged: Says whether a value that was raised is one of Ledger's own failures.

	A failure of Ledger's carries a tag on it rather than a message that has to be read back, so a
	module that must tell a settled answer from a thrown one asks here instead of matching text.
	This is the only place that knows the tag. Fault writes it, and the two places that decide
	whether to retry or to pass a failure along read it.

	Return type: A table with TAG and Is.
	Example usage:
		local Tagged = require("./Tagged")
		if Tagged.Is(Raised) then return end
--]=]

local TAG = "Ledger"

local function Is(Raised: unknown): boolean
	return type(Raised) == "table" and (Raised :: { [string]: unknown })[TAG] == true
end

return table.freeze({
	TAG = TAG,
	Is = Is,
})
