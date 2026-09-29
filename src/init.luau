--!strict
--!optimize 2

--[=[

	Ledger: Player data as a ledger, and not as a document.

	This file is the whole surface a game can reach. A client may require it to read Answer. Nothing
	here or in any module it requires may need the server when it is required, so every part that
	needs the server calls Errors.OnServer when it is called.

	Return type: A table with Answer.
	Example usage:
		local Ledger = require(ReplicatedStorage.Ledger)
		if Result == Ledger.Answer.Busy then
			print("try again later")
		end
--]=]

local Answer = require("@self/Core/Answer")

export type Answer = Answer.Answer

return table.freeze({
	Answer = Answer,
})
