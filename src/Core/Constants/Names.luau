--!strict

--[=[

	Names: Logic. The datastores Ledger keeps for itself.

	NUMBERS holds the counter keys servers take their numbers from.

	Return type: A table of the names.
	Example usage:
		local Counters = DataStoreService:GetDataStore(Names.NUMBERS)
--]=]

return {
	NUMBERS = "Ledger_Numbers",
}
