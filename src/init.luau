--!strict
--!optimize 2

--[=[

	Ledger: Player data as a ledger, and not as a document.

	New makes a store from a config, and CloseAll flushes every store before the server closes. A
	client may require this to read Answer. A call that needs the server checks with Errors.OnServer.

	Return type: A table with Answer, New and CloseAll.
	Example usage:
		local Gold = Ledger.New({ Name = "Gold", Default = { Gold = 0 }, Reducer = Reducer })
		if Result == Ledger.Answer.Busy then return end
--]=]

local Answer = require("@self/Core/Answer")
local Store = require("@self/Store/Store")

export type Answer = Answer.Answer
export type Store = Store.Store

return {
	Answer = Answer,
	New = Store.New,
	CloseAll = Store.CloseAll,
}
