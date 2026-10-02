--!strict
--!optimize 2

--[=[
	Answer: Logic. Every answer a call gives besides true.

	A game compares a reply against a field, Answer.Busy, so a misspelt name is a type error where a
	string would not be. The table is frozen, since every server and the client must agree on it.

	Return type: A frozen table from each name to itself, and the Answer type.
	Example usage:
		if Result == Answer.Busy then return end
--]=]

local Answer = table.freeze({
	Backlog = "Backlog" :: "Backlog",
	Behind = "Behind" :: "Behind",
	Busy = "Busy" :: "Busy",
	Closed = "Closed" :: "Closed",
	Expired = "Expired" :: "Expired",
	Full = "Full" :: "Full",
	Invalid = "Invalid" :: "Invalid",
	Missing = "Missing" :: "Missing",
	NoRoom = "NoRoom" :: "NoRoom",
	Refused = "Refused" :: "Refused",
	Short = "Short" :: "Short",
	SoldOut = "SoldOut" :: "SoldOut",
	Spent = "Spent" :: "Spent",
	Unresolved = "Unresolved" :: "Unresolved",
	Worn = "Worn" :: "Worn",
})

export type Answer = keyof<typeof(Answer)>

return Answer
