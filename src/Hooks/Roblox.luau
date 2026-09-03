--!strict
--!optimize 2

--[=[

	Roblox: The datastore and the MemoryStore Ledger writes to in a live game.

	DataStoreService and MemoryStoreService behind the shape everything else takes. It holds no
	state, so New hands back the same three functions every time.

	Return type: A table with New. It answers the Hook shape.
	Example usage:
		local Roblox = require("./Roblox")
		local Held = Roblox.New()
--]=]

local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")

local Engine = require("../Util/Engine")

export type Hook = Engine.Hook

local function Open(Name: string): Engine.Store
	return DataStoreService:GetDataStore(Name) :: any
end

local function Budget(Kind: Enum.DataStoreRequestType): number
	return DataStoreService:GetRequestBudgetForRequestType(Kind)
end

local function Cache(Name: string): Engine.Map
	return MemoryStoreService:GetHashMap(Name) :: any
end

local Held: Hook = table.freeze({
	Open = Open,
	Budget = Budget,
	Cache = Cache,
})

local function New(): Hook
	return Held
end

return table.freeze({
	New = New,
})
