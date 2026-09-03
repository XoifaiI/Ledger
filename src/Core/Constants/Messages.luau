--!strict
--!optimize 2

--[=[
	Messages: The strings Ledger raises and then reads back.

	Something matches each of these rather than only printing it, so the text is the interface. TAG is
	the field a failure of Ledger's carries, which tells it from any other raised value. ACCUSED heads
	every warning that names a bug in Ledger rather than one in the game. The suite fails a case on
	any such warning it did not ask for.

	Return type: A table with TAG, ACCUSED, YIELDED and SKIPPED.
	Example usage:
		local Messages = require("./Messages")
		if string.find(Raised, Messages.YIELDED, 1, true) then return end
--]=]

return table.freeze({
	TAG = "Ledger" :: "Ledger",
	ACCUSED = "Ledger bug:",
	YIELDED = "the callback must complete without yielding",
	SKIPPED = "ThreadQueue task skipped",
})
