--!strict
--!optimize 2

-- fills default keys missing from stored data, stored values always win so a returning player keeps theirs

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
