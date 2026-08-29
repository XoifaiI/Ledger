--!strict
--!optimize 2

--[=[
	Registry: The one list of stores that this server built.

	The sweep is built on first use, and not on require. To require Ledger therefore does not start
	a timer before a store exists.
	Choosing a scheduler moves the sweep's timer onto it. Without that the sweep keeps the timer it was
	born with, and every later run of a test holds a ticker on a scheduler that stopped, which never
	fires again. The sweep itself is kept, because anything that already asked for it holds it.

	Return type: A table with Stores, Claimed, Shutting and Sweep.
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
