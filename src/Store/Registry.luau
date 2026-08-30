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
local Shapes = require("../Core/Shapes")

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
local Sized: Shapes.Mocked? = nil

local function Same(Left: Shapes.Mocked?, Right: Shapes.Mocked?): boolean
	local Held: Shapes.Mocked = Left or {}
	local Asked: Shapes.Mocked = Right or {}
	return Held.Players == Asked.Players and Held.CCU == Asked.CCU and Held.Throttled == Asked.Throttled
end

local function Mock(Options: Shapes.Mocked?): Engine.Hook
	local Held = Mocked
	if Held ~= nil then
		assert(
			Options == nil or Same(Sized, Options),
			"the fake datastore is already sized, so a second store cannot ask for a different Players, CCU or Throttled. size it on the first store you build with Mock"
		)
		return Held
	end

	Held = Memory.New(Clock.Held(), Options)
	Mocked = Held
	Sized = Options
	return Held
end

local function Unmock()
	Mocked = nil
	Sized = nil
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
	Unmock = Unmock,
	Sweep = Walker,
})
