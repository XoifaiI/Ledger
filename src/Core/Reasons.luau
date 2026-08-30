--!strict
--!optimize 2

--[=[

	Reasons: Every answer Ledger gives when a write does not go through.

	The type and the values are in one file, and each value carries its own exact type.

	Return type: A frozen table of the ten reasons.
	Example usage:
		local Reasons = require("./Reasons")
		if Why == Reasons.Busy then Retry() end
--]=]

export type Reason = "Refused" | "Busy" | "Spent" | "Unresolved" | "Closed" | "Backlog" | "Full" | "Invalid" | "Behind" | "Held"

return table.freeze({
	Refused = "Refused" :: "Refused",
	Busy = "Busy" :: "Busy",
	Spent = "Spent" :: "Spent",
	Unresolved = "Unresolved" :: "Unresolved",
	Closed = "Closed" :: "Closed",
	Backlog = "Backlog" :: "Backlog",
	Full = "Full" :: "Full",
	Invalid = "Invalid" :: "Invalid",
	Behind = "Behind" :: "Behind",
	Held = "Held" :: "Held",
})
