--!strict
--!optimize 2

--[=[

	Answer: Every answer a call gives besides true.

	Compare against a field, so a misspelt name is a type error.

	Return type: A table from each name to itself.
	Example usage:
		if Result == Answer.Busy then return end
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

return Answer
