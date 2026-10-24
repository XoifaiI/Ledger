--!strict
--!optimize 2

--[=[
	Reasons: the answers of spec/properties/Answers.md section 4 other than `true`, each meaning one thing
	whatever the method. The Reason type and the table are written from the same fifteen names.

	Return type: The Reason type, and a frozen table that maps each answer's name to its text.
	Example usage:
		local Reasons = require("./Constants/Reasons")
		if Why == Reasons.Busy then ... end
--]=]

export type Reason =
	"Refused"
	| "Spent"
	| "Busy"
	| "Full"
	| "Invalid"
	| "Behind"
	| "Unreadable"
	| "Closed"
	| "Backlog"
	| "Expired"
	| "NoRoom"
	| "Missing"
	| "Short"
	| "SoldOut"
	| "Unresolved"

local Reasons = {
	Refused = "Refused" :: "Refused",
	Spent = "Spent" :: "Spent",
	Busy = "Busy" :: "Busy",
	Full = "Full" :: "Full",
	Invalid = "Invalid" :: "Invalid",
	Behind = "Behind" :: "Behind",
	Unreadable = "Unreadable" :: "Unreadable",
	Closed = "Closed" :: "Closed",
	Backlog = "Backlog" :: "Backlog",
	Expired = "Expired" :: "Expired",
	NoRoom = "NoRoom" :: "NoRoom",
	Missing = "Missing" :: "Missing",
	Short = "Short" :: "Short",
	SoldOut = "SoldOut" :: "SoldOut",
	Unresolved = "Unresolved" :: "Unresolved",
}

return table.freeze(Reasons)
