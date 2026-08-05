--!strict
--!optimize 2

--[=[
	Registry: The one list of stores that this server built.
	
	The sweep is built on first use, and not on require. To require Ledger therefore does not start
	a timer before a store exists.
	
	Return type: A table with Stores, Claimed, Shutting and Sweep.
	Example usage:
		local Registry = require("./Registry")
		Registry.Sweep():Add(Store, Key)
--]=]

local Sweeper = require("./Sweeper")
local Types = require("./Types")

type Store = Types.Store

local Stores: { Store } = {}
local Claimed: { [string]: boolean } = {}
local Shutting = { Now = false }

local Sweep: Sweeper.Sweeper? = nil

local function Walker(): Sweeper.Sweeper
	local Built = Sweep
	if Built ~= nil then
		return Built
	end

	Built = Sweeper.New(Stores)
	Sweep = Built
	return Built
end

return table.freeze({
	Stores = Stores,
	Claimed = Claimed,
	Shutting = Shutting,
	Sweep = Walker
})
