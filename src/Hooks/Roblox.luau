--!strict
--!optimize 2

--[=[
	Roblox: The datastore Ledger writes to in a live game.

	It is DataStoreService behind the one shape everything else takes, and it holds nothing, so New
	hands back the same pair every time.

	Return type: A table with New. It answers the Hook shape.
	Example usage:
		local Roblox = require("./Roblox")
		local Held = Roblox.New()
--]=]

local DataStoreService = game:GetService("DataStoreService")

local Engine = require("../Util/Engine")

export type Hook = Engine.Hook

local function Open(Name: string): Engine.Store
	return DataStoreService:GetDataStore(Name) :: any
end

local function Budget(Kind: Enum.DataStoreRequestType): number
	return DataStoreService:GetRequestBudgetForRequestType(Kind)
end

local Held: Hook = table.freeze({
	Open = Open,
	Budget = Budget,
})

local function New(): Hook
	return Held
end

return table.freeze({
	New = New,
})
