--!strict
--!optimize 2

--[=[
	Verdicts: What parking a transaction leg can answer, and what becomes of one being resolved.

	A prepare answers one of six: the leg went on, it was already settled, the key is busy, the reducer
	turned it away, the name is spent, or the record has no room. Resolving a leg then finds it either
	owned by the transaction deciding it or dead from an older use of the name.

	Return type: A table with the six answers and the two fates. The types are Prepared and Fated.
	Example usage:
		local Verdicts = require("./Verdicts")
		if Answer == Verdicts.BUSY then Wait() end
--]=]

export type Prepared = "Prepared" | "Settled" | "Busy" | "Rejected" | "Spent" | "Full"

export type Fated = "Owned" | "Dead"

return table.freeze({
	PREPARED = "Prepared" :: "Prepared",
	SETTLED = "Settled" :: "Settled",
	BUSY = "Busy" :: "Busy",
	REJECTED = "Rejected" :: "Rejected",
	SPENT = "Spent" :: "Spent",
	FULL = "Full" :: "Full",

	OWNED = "Owned" :: "Owned",
	DEAD = "Dead" :: "Dead",
})
