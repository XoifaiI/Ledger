--!strict
--!optimize 2

--[=[
	Verdicts: What parking a transaction leg can answer, and what becomes of one being resolved.

	A prepare answers one of seven. The leg went on, or it was already settled. The key is busy, or
	the reducer turned the leg away. The name is spent, or the record has no room. The key was erased,
	and stays turned away until its tomb runs out.

	Resolving a leg then finds it one of two things. The transaction deciding it owns the leg, or the
	leg is dead from an older use of the name.

	Return type: A table with the seven answers and the two fates. The types are Prepared and Fated.
	Example usage:
		local Verdicts = require("./Verdicts")
		if Answer == Verdicts.BUSY then Wait() end
--]=]

export type Prepared = "Prepared" | "Settled" | "Busy" | "Rejected" | "Spent" | "Full" | "Erased"

export type Fated = "Owned" | "Dead"

return table.freeze({
	PREPARED = "Prepared" :: "Prepared",
	SETTLED = "Settled" :: "Settled",
	BUSY = "Busy" :: "Busy",
	REJECTED = "Rejected" :: "Rejected",
	SPENT = "Spent" :: "Spent",
	FULL = "Full" :: "Full",
	ERASED = "Erased" :: "Erased",

	OWNED = "Owned" :: "Owned",
	DEAD = "Dead" :: "Dead",
})
