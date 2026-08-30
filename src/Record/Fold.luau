--!strict
--!optimize 2

--[=[

	Fold: Replays each op on top of a base state.

	An op the reducer refuses is skipped, and so is one carrying a transaction stamp, since no marker
	has decided that transaction yet.

	Return type: A function that gives back the state, and whether the marked op applied.
	Example usage:
		local Fold = require("./Fold")
		local State = Fold(Base, Record.Ops, Reducer)
--]=]

local TableUtil = require("../Util/TableUtil")
local Apply = require("./Apply")
local Shapes = require("../Core/Shapes")

local FreezeDelta = TableUtil.FreezeDelta

type Op = Shapes.Op
type Reducer<S> = Shapes.Reducer<S>

local function Fold<S>(Base: S, Ops: { Op }, Reducer: Reducer<S>, Mark: string?): (S, boolean)
	local State = FreezeDelta(Base)
	local Took = false

	for _, Op in Ops do
		if Op.Tx ~= nil then
			continue
		end
		local Next = Apply(Reducer, State, Op)
		if Next ~= nil then
			State = FreezeDelta(Next)
			if Op.Id == Mark then
				Took = true
			end
		end
	end

	return State, Took
end

return Fold
