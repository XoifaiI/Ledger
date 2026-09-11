--!strict
--!optimize 2

--[=[

	Layers: The reducer stack under one name.

	A store hands over the field it calls a balance and its own reducer, and gets back the reducer
	every write actually runs through, plus the set of kinds the stack answers for rather than the
	game. It does not have to know which features there are, what order they wrap in, or that Names
	goes around the outside rather than inside.

	Names is not one of the layers. It has to see the state a write folds to after the game reducer
	has had it, so it wraps the stack rather than joining it, and this is the one place that knows
	the difference.

	Return type: A table with Built. The type is Layer.
	Example usage:
		local Layers = require("../Layers")
		local Reducer, Handles = Layers.Built(Config.Balance, Config.Reducer)
--]=]

local Shapes = require("@self/../Core/Shapes")
local Escrow = require("@self/Escrow")
local Layer = require("@self/Layer")
local Names = require("@self/Names")
local Tally = require("@self/Tally")

type Reducer<S> = Shapes.Reducer<S>

export type Layer = Layer.Layer

local FEATURES: { (Balance: string?) -> Layer.Layer } = table.freeze({ Escrow.Layered, Tally.Layered })

local function Built<S>(Balance: string?, Game: Reducer<S>): (Reducer<S>, { [string]: boolean })
	local Held: { Layer.Layer } = table.create(#FEATURES) :: { Layer.Layer }
	for Index, Feature in FEATURES do
		Held[Index] = Feature(Balance)
	end

	return Names.Wrap(Layer.Stack(Held, Game)), Layer.Handles(Held)
end

return table.freeze({
	Built = Built,
})
