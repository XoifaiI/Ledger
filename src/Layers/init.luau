--!strict
--!optimize 2

--[=[

	Layers: The reducer stack under one name.

	A store hands over the field it calls a balance, its own reducer, its default state and its
	migrations. It gets back the reducer every write actually runs through, plus the set of kinds the
	stack answers for rather than the game. It does not have to know which features there are, what
	order they wrap in, or that Names and Reset go around the outside rather than inside.

	Names and Reset are not layers. Names has to see the state a write folds to after the game
	reducer has had it, and Reset has to answer its op before anything else sees it. So each wraps
	the stack rather than joining it, Reset outermost, and this is the one place that knows the
	difference.

	Return type: A table with Built. The type is Layer.
	Example usage:
		local Layers = require("../Layers")
		local Reducer, Handles = Layers.Built(Config.Balance, Config.Reducer, Initial, Steps)
--]=]

local Shapes = require("./Core/Shapes")
local Escrow = require("@self/Escrow")
local Layer = require("@self/Layer")
local Names = require("@self/Names")
local Reset = require("@self/Reset")
local Tally = require("@self/Tally")

type Reducer<S> = Shapes.Reducer<S>
type Migration = Shapes.Migration

export type Layer = Layer.Layer

local FEATURES: { (Balance: string?) -> Layer.Layer } = table.freeze({ Escrow.Layered, Tally.Layered })

local function Built<S>(Balance: string?, Game: Reducer<S>, Initial: S, Steps: { Migration }): (Reducer<S>, { [string]: boolean })
	local Held: { Layer.Layer } = table.create(#FEATURES) :: { Layer.Layer }
	for Index, Feature in FEATURES do
		Held[Index] = Feature(Balance)
	end

	return Reset.Wrap(Names.Wrap(Layer.Stack(Held, Game)), Initial, Steps), Layer.Handles(Held)
end

return table.freeze({
	Built = Built,
})
