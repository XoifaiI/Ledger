--!strict
--!optimize 2

--[=[
	Messages: The values Ledger raises or prints and then reads back.

	Something reads each of these back rather than only printing it. TAG is the field a failure of
	Ledger's carries, which tells it from any other raised value. ACCUSED heads every warning that
	names a bug in Ledger rather than one in the game. The suite fails a case on any such warning it
	did not ask for. SKIPPED is what a write the queue dropped raises. It is compared by what it is,
	never by its text, and it prints as its message.

	Return type: A table with TAG, ACCUSED and SKIPPED.
	Example usage:
		local Messages = require("./Messages")
		if Raised == Messages.SKIPPED then return end
--]=]

local SKIPPED = "ThreadQueue task skipped"

local Printed = table.freeze({
	__tostring = function(): string
		return SKIPPED
	end,
})

return table.freeze({
	TAG = "Ledger" :: "Ledger",
	ACCUSED = "Ledger bug:",
	SKIPPED = table.freeze(setmetatable({}, Printed)),
})
