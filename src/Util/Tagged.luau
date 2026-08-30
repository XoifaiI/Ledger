--!strict
--!optimize 2

--[=[
	Tagged: Says whether a raised value is one of Ledger's own failures.

	Ledger's failures carry a tag rather than a message to be read back, so anything telling a settled
	answer from a thrown one asks here instead of matching text. This is the only place that knows the
	tag.

	Return type: A table with Is.
	Example usage:
		local Tagged = require("./Tagged")
		if Tagged.Is(Raised) then return end
--]=]

local Messages = require("../Core/Constants/Messages")

local function Is(Raised: unknown): boolean
	return type(Raised) == "table" and (Raised :: { [string]: unknown })[Messages.TAG] == true
end

return table.freeze({
	Is = Is,
})
