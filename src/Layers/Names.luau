--!strict
--!optimize 2

--[=[
	Names: Writes down the name that an op ran under.

	The same name cannot then run two times. This sits outside each other layer, because it must see
	the state after the game reducer has had it.
	This is not a plain layer. It refuses an op before the reducer runs, and its message names the op.

	Return type: A table with Wrap.
	Example usage:
		local Names = require("./Names")
		local Reducer = Names.Wrap(Inner)
--]=]

local TableUtil = require("../Util/TableUtil")
local Errors = require("../Core/Errors")
local Shapes = require("../Core/Shapes")
local Applied = require("../Core/Applied")
local Storable = require("../Encode/Storable")

type Op = Shapes.Op
type Reducer<S> = Shapes.Reducer<S>

local function StampOf(Op: Op): (string?, any, string?)
	local Sticky = Op.TxSticky
	if type(Sticky) == "string" then
		local Print = if type(Op.TxTerms) == "string" then Op.TxTerms else nil
		return Applied.Key(Applied.TX, Sticky), Op.TxAt, Print
	end

	local Once = Op.Once
	if type(Once) == "string" then
		return Applied.Key(Applied.ONCE, Once), Op.OnceAt, nil
	end
	return nil, nil, nil
end

local function Wrap<S>(Inner: Reducer<S>): Reducer<S>
	local function Combined(State: S, Op: Op): S?
		local Data: any = State
		if type(Op.Once) == "string" and Applied.Has(Data._Received, Applied.ONCE, Op.Once) then
			return nil
		end

		local Next = Inner(State, Op)
		if type(Next) ~= "table" then
			return Next
		end
		local Plain: any = Next

		local Stamp, At, Print = StampOf(Op)
		if Stamp ~= nil then
			if type(At) ~= "number" then
				Errors.Broke(`op '{tostring(Op.Kind)}' carries a name with no time on it, so the name could never be aged out`)
				return nil
			end
			local Marked = table.clone(Plain)
			Marked._Received = Applied.Remember(Data._Received, Stamp, At, Print)
			return Marked :: any
		end

		local Touched = Plain._Received ~= Data._Received and not Storable.Reserved(Op.Kind)
		if not Touched then
			return Next
		end

		if Plain._Received ~= nil and not TableUtil.DeepEqual(Plain._Received, Data._Received) then
			Errors.Broke(`your reducer wrote its own _Received on op '{tostring(Op.Kind)}', so Ledger put the applied names back`)
		end

		local Kept = table.clone(Plain)
		Kept._Received = Data._Received
		return Kept :: any
	end

	return Combined
end

return table.freeze({
	Wrap = Wrap,
})
