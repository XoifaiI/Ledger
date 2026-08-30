--!strict
--!optimize 2

--[=[

	Registry: The one list of stores this server built.

	It holds the stores, the names they claimed, whether a shutdown is running, and the scheduler and
	hook a store is built with by default. Use replaces those defaults and refuses once a store is
	live. The sweep is built on first use rather than on require.

	Return type: A table with Stores, Claimed, Shutting, Defaults, Use and Sweep.
	Example usage:
		local Registry = require("./Registry")
		Registry.Sweep():Add(Store:Swept(), Key)
--]=]

local RobloxHook = require("../Hooks/Roblox")
local RobloxScheduler = require("../Schedulers/Roblox")
local Clock = require("../Util/Clock")
local Engine = require("../Util/Engine")

local Sweeper = require("./Sweeper")
local Types = require("./Types")

type Store = Types.Store<any>

export type Sweeper = Sweeper.Sweeper

local Stores: { Store } = {}
local Claimed: { [string]: boolean } = {}
local Shutting = { Now = false }

local Defaults: { Scheduler: Engine.Scheduler, Hook: Engine.Hook } = {
	Scheduler = RobloxScheduler.New(),
	Hook = RobloxHook.New(),
}

local Sweep: Sweeper.Sweeper? = nil

local function Use(Scheduler: Engine.Scheduler?, Hook: Engine.Hook?)
	assert(#Stores == 0, `Ledger: {#Stores} store(s) are already built, so choosing a scheduler or a datastore now would leave them on the old one. do it before you build your stores`)
	Defaults.Scheduler = Scheduler or RobloxScheduler.New()
	Defaults.Hook = Hook or RobloxHook.New()

	Clock.Use(Scheduler)

	local Held = Sweep
	if Held ~= nil then
		Held:Retime()
	end
end

local function Walker(): Sweeper.Sweeper
	local Built = Sweep
	if Built ~= nil then
		return Built
	end

	Built = Sweeper.New()
	Sweep = Built
	return Built
end

return table.freeze({
	Stores = Stores,
	Claimed = Claimed,
	Shutting = Shutting,
	Defaults = Defaults,
	Use = Use,
	Sweep = Walker,
})
