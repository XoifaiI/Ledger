--!strict
--!optimize 2

--[=[
	Names: Writes down the name that an op ran under.

	The same name cannot then run two times. This sits outside each other layer, because it must see
	the state after the game reducer has had it.
	This is not a plain layer. It refuses an op before the reducer runs, and its message names the op.

	Return type: A table with Wrap and StampOf.
	Example usage:
		local Names = require("./Names")
		local Reducer = Names.Wrap(Inner)
--]=]

local Fault = require("../Contract/Fault")
local Contract = require("../Contract/Op")
local Entries = require("../Kernel/Entries")
local IsStorable = require("../Encode/Storable")

type Op = Contract.Op
type Reducer<S> = Contract.Reducer<S>

local function StampOf(Op: Op): (string?, any, string?)
	local Sticky = Op.TxSticky
	if type(Sticky) == "string" then
		local Print = if type(Op.TxTerms) == "string" then Op.TxTerms else nil
		return Entries.Key(Entries.TX, Sticky), Op.TxAt, Print
	end

	local Once = Op.Once
	if type(Once) == "string" then
		return Entries.Key(Entries.ONCE, Once), Op.OnceAt, nil
	end
	return nil, nil, nil
end

local function Wrap<S>(Inner: Reducer<S>): Reducer<S>
	local function Combined(State: S, Op: Op): S?
		local Data: any = State
		if type(Op.Once) == "string" and Entries.Has(Data._Received, Entries.ONCE, Op.Once) then
			return nil
		end

		local Next = Inner(State, Op)
		if type(Next) ~= "table" then
			return Next
		end
		local Plain: any = Next

		local Stamp, At, Print = StampOf(Op)
		if Stamp ~= nil then
			local Marked = table.clone(Plain)
			Marked._Received = Entries.Remember(Data._Received, Stamp, At, Print)

			if (Marked._Received :: any)[Stamp] == nil then
				Fault.Broke(`op '{tostring(Op.Kind)}' applied under a name that was not written down, so it could apply again`)
				return nil
			end
			return Marked :: any
		end

		local Touched = Data._Received ~= nil and Plain._Received ~= Data._Received and not IsStorable.Reserved(Op.Kind)
		if not Touched then
			return Next
		end

		if Plain._Received ~= nil then
			Fault.Broke(`your reducer wrote its own _Received on op '{tostring(Op.Kind)}', so Ledger put the applied names back`)
		end

		local Kept = table.clone(Plain)
		Kept._Received = Data._Received
		return Kept :: any
	end

	return Combined
end

return table.freeze({
	Wrap = Wrap,
	StampOf = StampOf,
})
