--!strict
--!optimize 2

--[=[
	Messages: The strings Ledger raises and then reads back.

	Each of these is matched somewhere rather than only printed, so the text is the interface. TAG is
	the field a failure of Ledger's carries so it can be told from any other raised value.

	Return type: A table with TAG, YIELDED and SKIPPED.
	Example usage:
		local Messages = require("./Messages")
		if string.find(Raised, Messages.YIELDED, 1, true) then return end
--]=]

return table.freeze({
	TAG = "Ledger",
	YIELDED = "the callback must complete without yielding",
	SKIPPED = "ThreadQueue task skipped",
})
