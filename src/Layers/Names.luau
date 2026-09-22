--!strict
--!optimize 2

--[=[

	Names: Writes down the name an op ran under, so the same name cannot run twice.

	It wraps the other layers rather than sitting beside them, since it has to see the state after the
	game reducer has had it. It also refuses an op whose name is already written down, before the
	reducer runs at all. Escrow owns _Received, and puts it back when a game reducer writes it.

	Return type: A table with Wrap.
	Example usage:
		local Names = require("./Names")
		local Reducer = Names.Wrap(Inner)
--]=]

local Shapes = require("../Core/Shapes")
local Messages = require("../Core/Constants/Messages")
local Tags = require("../Core/Constants/Tags")
local Applied = require("../Core/Applied")

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
		if Stamp == nil then
			return Next
		end
		if type(At) ~= "number" then
			warn(`{Messages.ACCUSED} op '{tostring(Op.Kind)}' carries a name with no time on it. Ledger turned the op away, please report this`)
			return nil
		end

		local Marked = table.clone(Plain)
		Marked._Received = Applied.Remember(Data._Received, Stamp, At, Print)
		return Marked :: any
	end

	return Combined
end

return table.freeze({
	Wrap = Wrap,
})
