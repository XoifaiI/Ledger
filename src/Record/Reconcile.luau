--!strict
--!optimize 2

--[=[

	Reconcile: Adds each default key the stored data does not have.

	A stored value always wins, so a player coming back keeps what they had.

	Return type: A function that gives back the stored table, or a copy of it with the defaults in.
	Example usage:
		local Reconcile = require("./Reconcile")
		local Ready = Reconcile(Default, Stored)
--]=]

local TableUtil = require("../Util/TableUtil")

local function Reconcile(Defaults: any, Stored: any): any
	if type(Defaults) ~= "table" or type(Stored) ~= "table" then
		return Stored
	end

	local Next = Stored
	for Key, Value in Defaults do
		local Theirs = Next[Key]
		if Theirs == nil then
			if Next == Stored then
				Next = table.clone(Stored)
			end
			Next[Key] = TableUtil.DeepCopy(Value)
		elseif type(Value) == "table" and #Value == 0 then
			local Inner = Reconcile(Value, Theirs)
			if Inner ~= Theirs then
				if Next == Stored then
					Next = table.clone(Stored)
				end
				Next[Key] = Inner
			end
		end
	end

	return Next
end

return Reconcile
