--!strict

--[=[
	Limits: Logic. The hard bounds more than one feature reads.

	EPOCH is the unix time a stamp counts from, and STAMP_MAX the largest stamp. MONEY_LIMIT is one
	past the largest whole amount a double holds exactly, so every money check is against it. TRIES
	is how many failed requests make an op answer Unresolved. MAPS is how many MemoryStore maps each
	purpose spreads its items over. A bound only one feature reads lives in that feature's module.

	Return type: A table of the bounds.
	Example usage:
		if Stamp > Limits.STAMP_MAX then return end
--]=]

return {
	EPOCH = 1767225600,
	STAMP_MAX = 2 ^ 40,
	WRITES_MAX = 2 ^ 53 - 1,
	MONEY_LIMIT = 2 ^ 53,
	MONEY_MAX = 64,
	NAME_BYTES = 48,
	DEPTH_MAX = 64,
	TRIES = 3,
	SHOWN_MAX = 4096,
	MAPS = 16,
	LEGS_MIN = 2,
}
