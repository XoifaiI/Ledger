--!strict
--!optimize 2

--[=[

	Ledger: Player data as a ledger, and not as a document.

	A client may require this to read Answer. A call that needs the server checks with
	Errors.OnServer.

	Return type: A table with Answer.
	Example usage:
		if Result == Ledger.Answer.Busy then return end
--]=]

local Answer = require("@self/Core/Answer")

export type Answer = Answer.Answer

return {
	Answer = Answer,
}
