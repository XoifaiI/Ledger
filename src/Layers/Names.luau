--!strict
--!optimize 2

--[=[

	Names: Writes down the name an op ran under, so the same name cannot run twice.

	It wraps the other layers rather than sitting beside them, since it has to see the state after the
	game reducer has had it. It also refuses an op whose name is already written down, before the
	reducer runs at all.

	Return type: A table with Wrap.
	Example usage:
		local Names = require("./Names")
		local Reducer = Names.Wrap(Inner)
--]=]

local TableUtil = require("../Util/TableUtil")
local Shapes = require("../Core/Shapes")
local Messages = require("../Core/Constants/Messages")
local Tags = require("../Core/Constants/Tags")
local Applied = require("../Core/Applied")
local Storable = require("../Encode/Storable")

type Op = Shapes.Op
type Reducer<S> = Shapes.Reducer<S>

local function StampOf(Op: Op): (string?, any, string?)
	local Sticky = Op.TxSticky
	if type(Sticky) == "string" then
		local Print = if type(Op.TxTerms) == "string" then Op.TxTerms else nil
		return Applied.Key(Tags.TX, Sticky), Op.TxAt, Print
	end

	local Once = Op.Once
	if type(Once) == "string" then
		return Applied.Key(Tags.ONCE, Once), Op.OnceAt, nil
	end
	return nil, nil, nil
end

local function Wrap<S>(Inner: Reducer<S>): Reducer<S>
	local function Combined(State: S, Op: Op): S?
		local Data: any = State
		if type(Op.Once) == "string" and Applied.Has(Data._Received, Tags.ONCE, Op.Once) then
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
				warn(`{Messages.ACCUSED} op '{tostring(Op.Kind)}' carries a name with no time on it. Ledger turned the op away, please report this`)
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
			warn(`Ledger: your reducer wrote its own _Received on op '{tostring(Op.Kind)}'. Ledger put the applied names back, leave fields starting with an underscore alone`)
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
