--!strict
--!optimize 2

--[=[

	Memory: The datastore Ledger writes to in a test.

	The mock behind the shape the real one takes, so a store cannot tell which it was handed. Two
	hooks over one service are two servers on one datastore.

	Return type: A table with New. The type is Memory.
	Example usage:
		local Held = Memory.New(Turn)
		local Beside = Memory.New(Turn, nil, Held.Service)
--]=]

local Engine = require("../Util/Engine")
local Mock = require("../Mock")
local Roblox = require("../Schedulers/Roblox")

export type Memory = {
	read Open: (Name: string) -> Engine.Store,
	read Budget: (Kind: Enum.DataStoreRequestType) -> number,
	read Service: Mock.Service,
}

local function New(Scheduler: Engine.Scheduler?, Options: Mock.Options?, Shared: Mock.Service?): Memory
	local Turn = Scheduler or Roblox.New()
	local Service = Shared or Mock.New(Options, Turn)

	return table.freeze({
		Service = Service,

		Open = function(Name: string): Engine.Store
			return Service:GetDataStore(Name) :: any
		end,

		Budget = function(Kind: Enum.DataStoreRequestType): number
			return Service:GetRequestBudgetForRequestType(Kind)
		end,
	})
end

return table.freeze({
	New = New,
})
