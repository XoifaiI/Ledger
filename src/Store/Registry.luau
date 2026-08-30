--!strict
--!optimize 2

--[=[

	Registry: The one list of stores this server built.

	It holds the stores, the names they claimed, whether a shutdown is running, and the scheduler and
	hook a store is built with by default. Use replaces those defaults and refuses once a store is
	live. The sweep is built on first use rather than on require.

	Return type: A table with Stores, Claimed, Shutting, Defaults, Mock and Sweep.
	Example usage:
		local Registry = require("./Registry")
		Registry.Sweep():Add(Store:Swept(), Key)
--]=]

local Memory = require("../Hooks/Memory")
local RobloxHook = require("../Hooks/Roblox")
local Clock = require("../Util/Clock")
local Engine = require("../Util/Engine")

local Sweeper = require("./Sweeper")
local Types = require("./Types")

type Store = Types.Store<any>

export type Sweeper = Sweeper.Sweeper

local Stores: { Store } = {}
local Claimed: { [string]: boolean } = {}
local Shutting = { Now = false }

local Defaults: { Hook: Engine.Hook } = {
	Hook = RobloxHook.New(),
}

local Sweep: Sweeper.Sweeper? = nil

local Mocked: Engine.Hook? = nil

local function Mock(): Engine.Hook
	local Held = Mocked
	if Held ~= nil then
		return Held
	end

	Held = Memory.New(Clock.Held())
	Mocked = Held
	return Held
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
	Mock = Mock,
	Sweep = Walker,
})
