--!strict
--!optimize 2

--[=[
	Layer: Puts the reducer layers of one key in order.
	
	A layer names the op kinds that it handles, and the bookkeeping fields that it owns.
	A game reducer that writes one of those fields gets that field put back.
	A layer that is added later therefore cannot forget to protect its own field.
	
	Return type: A table with Wrap and Stack.
	Example usage:
		local Layer = require("./Layer")
		local Reducer = Layer.Stack({ Escrow, Booking }, Game)
--]=]

local Fault = require("../Contract/Fault")
local Op = require("../Contract/Op")

type Op = Op.Op
type Reducer<S> = Op.Reducer<S>

type Data = { [any]: any }

export type Owned = {
	Field: string,
	Says: string
}

export type Layer = {
	Kinds: { [string]: (Data, Op) -> Data? },
	Owns: { Owned }?
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

	for _, Owned in Owns do
		if Plain[Owned.Field] ~= nil and Plain[Owned.Field] ~= Data[Owned.Field] then
			Fault.Broke(`your reducer wrote its own {Owned.Field}, so Ledger put {Owned.Says} back`)
		end
	end

	local Merged = table.clone(Plain)
	for _, Owned in Owns do
		Merged[Owned.Field] = Data[Owned.Field]
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

local function Stack<S>(Layers: { Layer }, GameReducer: Reducer<S>): Reducer<S>
	local Built = GameReducer
	for _, Layer in Layers do
		Built = Wrap(Built, Layer)
	end
	return Built
end

return table.freeze({
	Wrap = Wrap,
	Stack = Stack
})
