--!strict
--!optimize 2

--[=[
    Reconcile: fills any default keys missing from stored data, recursing into dictionaries (arrays are left whole).

    stored values always win, so a returning player keeps their data but picks up newly
    added defaults. that makes default keys permanent: a key present in the Default is
    refilled whenever it is absent, so a game cannot delete one, only mutate it to an
    empty or zero value. a field that needs to be able to be absent should not live in
    the Default at all.

    Return type: the Reconcile function
    Example usage:
        local Reconcile = require("./Reconcile")
        local Merged = Reconcile(Defaults, Stored)
--]=]

local TableUtil = require("./Util/TableUtil")

local function Reconcile(Defaults: any, Stored: any): any
	if type(Defaults) ~= "table" or type(Stored) ~= "table" then
		return Stored
	end

	for Key, Value in Defaults do
		if Stored[Key] == nil then
			Stored[Key] = if type(Value) == "table" then TableUtil.DeepCopy(Value) else Value
		elseif type(Value) == "table" and #Value == 0 then
			Reconcile(Value, Stored[Key])
		end
	end

	return Stored
end

return Reconcile
