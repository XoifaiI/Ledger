--!strict
--!optimize 2

--[=[

	Errors: The two ways Ledger speaks up that are not answers.

	Misuse throws at the game's own call when it was handed something it cannot use. Bug warns when
	Ledger caught its own mistake, and every such warning starts with BUG, so a test fails on one it
	did not ask for. What the datastore or another server did is never thrown: it comes back as an
	answer.

	Return type: A table with Misuse, Bug and BUG.
	Example usage:
		local Errors = require("./Errors")
		Errors.Misuse("a transaction needs at least two legs")
--]=]

local BUG = "Ledger bug:"

local function Misuse(Message: string, Depth: number?): never
	error(`Ledger: {Message}`, 3 + (Depth or 0))
end

local function Bug(Message: string)
	warn(`{BUG} {Message}. please report this`)
end

return table.freeze({
	Misuse = Misuse,
	Bug = Bug,
	BUG = BUG,
})
