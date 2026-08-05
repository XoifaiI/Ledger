--!strict
--!optimize 2

--[=[
	Reconcile: Adds each default key that the stored data does not have.
	
	A stored value always wins. A player who comes back therefore keeps what they had.
	
	Return type: A function that gives back the stored table.
	Example usage:
		local Reconcile = require("./Reconcile")
		local Ready = Reconcile(Default, Stored)
--]=]

local TableUtil = require("../Util/TableUtil")

local function Reconcile(Defaults: any, Stored: any): any
	if type(Defaults) ~= "table" or type(Stored) ~= "table" then
		return Stored
	end

	for Key, Value in Defaults do
		if Stored[Key] == nil then
			Stored[Key] = TableUtil.DeepCopy(Value)
		elseif type(Value) == "table" and #Value == 0 then
			Reconcile(Value, Stored[Key])
		end
	end

	return Stored
end

return Reconcile
