--!strict
--!optimize 2

--[=[

	Layer: Puts the reducer layers of one key in order.

	A layer names the op kinds it handles and the bookkeeping fields it owns. A kind a layer handles
	never reaches the layers below it, and a game reducer that writes an owned field gets that field
	put back.

	Return type: A table with Wrap, Stack and Handles.
	Example usage:
		local Layer = require("./Layer")
		local Reducer = Layer.Stack({ Escrow, Tally }, Game)
--]=]

local TableUtil = require("../Util/TableUtil")
local Shapes = require("../Core/Shapes")

type Op = Shapes.Op
type Reducer<S> = Shapes.Reducer<S>

type Data = { [any]: any }

export type Owned = {
	Field: string,
	Says: string,
}

export type Layer = {
	Kinds: { [string]: (Data, Op) -> Data? },
	Owns: { Owned }?,
}

local NONE: { Owned } = table.freeze({}) :: any

local function Carried(Next: any, Data: Data, Owns: { Owned }): any
	if type(Next) ~= "table" then
		return Next
	end

	local Plain = Next :: Data
	local Same = true
	for _, Owned in Owns do
		if Plain[Owned.Field] ~= Data[Owned.Field] then
			Same = false
			break
		end
	end
	if Same then
		return Next
	end

	local Merged = table.clone(Plain)
	for _, Owned in Owns do
		local Ours = Data[Owned.Field]
		local Theirs = Plain[Owned.Field]
		if Theirs ~= nil and Theirs ~= Ours and not TableUtil.DeepEqual(Theirs, Ours) then
			warn(`Ledger: your reducer wrote its own {Owned.Field}. Ledger put {Owned.Says} back, leave fields starting with an underscore alone`)
		end
		Merged[Owned.Field] = Ours
	end
	return Merged
end

local function Wrap<S>(Inner: Reducer<S>, Layer: Layer): Reducer<S>
	local Kinds = Layer.Kinds
	local Owns = Layer.Owns or NONE

	local function Combined(State: S, Op: Op): S?
		local Handle = Kinds[Op.Kind]
		if Handle ~= nil then
			return Handle(State :: any, Op) :: any
		end

		return Carried(Inner(State, Op), State :: any, Owns) :: any
	end

	return Combined
end

local function Handles(Layers: { Layer }): { [string]: boolean }
	local Named: { [string]: boolean } = {}
	for _, Layer in Layers do
		for Kind in Layer.Kinds do
			Named[Kind] = true
		end
	end
	return table.freeze(Named)
end

local function Stack<S>(Layers: { Layer }, GameReducer: Reducer<S>): Reducer<S>
	local Built = GameReducer
	for _, Layer in Layers do
		Built = Wrap(Built, Layer)
	end
	return Built
end

return table.freeze({
	Wrap = Wrap,
	Stack = Stack,
	Handles = Handles,
})
