--!strict
--!optimize 2

--[=[

	Answer: Every answer a call gives besides true.

	A call answers true when its work is done, and one of these names otherwise. Compare against a
	field, Answer == Ledger.Answer.Busy, so a misspelt name is a type error and the editor lists the
	names. Each call's own type says which of them it can give.

	Return type: A frozen table from each name to itself.
	Example usage:
		local Answer = require("./Answer")
		if Result == Answer.Busy then
			print("try again later")
		end
--]=]

export type Answer = "Backlog" | "Behind" | "Busy" | "Closed" | "Expired" | "Full" | "Invalid" | "Missing" | "NoRoom" | "Refused" | "Short" | "SoldOut" | "Spent" | "Unresolved" | "Worn"

local Answer: {
	read Backlog: "Backlog",
	read Behind: "Behind",
	read Busy: "Busy",
	read Closed: "Closed",
	read Expired: "Expired",
	read Full: "Full",
	read Invalid: "Invalid",
	read Missing: "Missing",
	read NoRoom: "NoRoom",
	read Refused: "Refused",
	read Short: "Short",
	read SoldOut: "SoldOut",
	read Spent: "Spent",
	read Unresolved: "Unresolved",
	read Worn: "Worn",
} =
	{
		Backlog = "Backlog",
		Behind = "Behind",
		Busy = "Busy",
		Closed = "Closed",
		Expired = "Expired",
		Full = "Full",
		Invalid = "Invalid",
		Missing = "Missing",
		NoRoom = "NoRoom",
		Refused = "Refused",
		Short = "Short",
		SoldOut = "SoldOut",
		Spent = "Spent",
		Unresolved = "Unresolved",
		Worn = "Worn",
	}

return table.freeze(Answer)
