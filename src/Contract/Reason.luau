--!strict
--!optimize 2

--[=[
	Reason: Names each answer that Ledger gives when a write does not go through.

	The type and the values are in one file. A new reason is therefore added one time, not two times.
	Each value carries its own exact type. To compare against one of these catches a name that does
	not exist. To compare against a plain string instead lets the checker prove that a chain of
	comparisons handles every reason. Use both together to get both.

	Return type: A frozen table of the ten reasons.
	Example usage:
		local Reasons = require("./Reason")
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
