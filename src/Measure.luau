--!strict
--!optimize 2

--[=[
    Measure: rough serialized byte size of a stored value.

    records and profiles are acyclic by construction (IsStorable rejects cycles, the
    datastore cannot hold one) so no cycle guard is needed. used to keep a live profile
    and its stored record under the 4mb datastore value ceiling before a write can
    wedge on it.

    Return type: the Measure function
    Example usage:
        local Measure = require("./Measure")
        local Bytes = Measure(State)
--]=]

local function StringBytes(Value: string): number
	local _, Escapes = string.gsub(Value, '["\\]', "")
	local _, Controls = string.gsub(Value, "%c", "")
	return #Value + 2 + Escapes + 5 * Controls
end

local function Measure(Value: any): number
	local Kind = type(Value)
	if Kind == "string" then
		return StringBytes(Value)
	elseif Kind == "number" then
		return math.max(8, #tostring(Value))
	elseif Kind == "boolean" then
		return 5
	elseif Kind ~= "table" then
		return 0
	end

	local Total = 2
	for Key, Inner in Value do
		if type(Key) == "string" then
			Total += #Key + 3
		end
		Total += Measure(Inner) + 1
	end
	return Total
end

return Measure
