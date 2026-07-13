--!strict
--!optimize 2

--[=[
    Storable: the one guard the data system runs on every op before it is stored.

    a value the datastore cannot serialize would otherwise sit in a session's pending
    queue and wedge every save on that key once the write throws, so it is rejected
    here, loudly, with the path to the offending value.

    it also rejects any op whose kind uses the reserved __ prefix (those belong to the
    internal protocols and must not be forged from outside) and any op carrying a
    PurchaseId or Tx field, which are reserved for the receipt and transaction paths so
    a game op can never impersonate either.

    only what survives a datastore round trip passes: finite numbers, valid utf8
    strings, booleans, and plain acyclic tables with no metatable, bounded depth, and
    either pure array or pure string keys. everything else is caught: functions,
    instances, vectors, nan and inf, non utf8 gibberish, cycles, metatables, tables
    nested past the depth cap, mixed or sparse arrays, and anything over the per op
    byte limit.

    Return type: frozen table { Op, Value }, the op guard and the bare value guard
    Example usage:
        local IsStorable = require("./Storable")
        local Ok, Reason = IsStorable.Op(Op)
        local Fits, Why = IsStorable.Value(Default)
--]=]

local Measure = require("./Measure")

local MAX_DEPTH = 64
local MAX_BYTES = 1024 * 1024

local OVER = `op is larger than the {MAX_BYTES} byte per op limit`

local Check: (Value: any, Path: string, Seen: { [any]: boolean }, Depth: number) -> (boolean, string)

local function CheckTable(Value: { [any]: any }, Path: string, Seen: { [any]: boolean }, Depth: number): (boolean, string)
	local ArrayKeys = 0
	local StringKeys = 0
	for Key in Value do
		local KeyKind = type(Key)
		if KeyKind == "number" then
			if Key % 1 ~= 0 or Key < 1 then
				return false, `{Path} has a non integer or non positive key`
			end
			ArrayKeys += 1
		elseif KeyKind == "string" then
			if utf8.len(Key) == nil then
				return false, `{Path} has a key that is not valid utf8`
			end
			StringKeys += 1
		else
			return false, `{Path} has a {typeof(Key)} key`
		end
	end

	if ArrayKeys > 0 and StringKeys > 0 then
		return false, `{Path} mixes array and string keys`
	end

	for Index = 1, ArrayKeys do
		if Value[Index] == nil then
			return false, `{Path} is a sparse array`
		end
	end

	for Key, Inner in Value do
		local Ok, Where = Check(Inner, `{Path}.{Key}`, Seen, Depth + 1)
		if not Ok then
			return false, Where
		end
	end

	return true, Path
end

function Check(Value: any, Path: string, Seen: { [any]: boolean }, Depth: number): (boolean, string)
	local Kind = type(Value)

	if Kind == "number" then
		if Value ~= Value or Value == math.huge or Value == -math.huge then
			return false, `{Path} is nan or inf`
		end
		return true, Path
	elseif Kind == "string" then
		if utf8.len(Value) == nil then
			return false, `{Path} is not valid utf8`
		end
		return true, Path
	elseif Kind == "boolean" then
		return true, Path
	elseif Kind ~= "table" then
		return false, `{Path} is a {typeof(Value)}`
	end

	if Depth > MAX_DEPTH then
		return false, `{Path} nests deeper than {MAX_DEPTH} levels`
	end
	if getmetatable(Value) ~= nil then
		return false, `{Path} has a metatable`
	end
	if Seen[Value] then
		return false, `{Path} is cyclic`
	end

	Seen[Value] = true
	local Ok, Where = CheckTable(Value, Path, Seen, Depth)
	Seen[Value] = nil
	return Ok, Where
end

local function IsStorable(Op: any): (boolean, string?)
	if type(Op) == "table" and type(Op.Kind) == "string" and string.sub(Op.Kind, 1, 2) == "__" then
		return false, `kind '{Op.Kind}' uses the __ prefix reserved for the framework's internal ops`
	end

	if type(Op) == "table" and Op.PurchaseId ~= nil then
		return false, "the PurchaseId field is reserved for the product receipt path"
	end

	if type(Op) == "table" and Op.Tx ~= nil then
		return false, "the Tx field is reserved for the transaction path"
	end

	local Ok, Where = Check(Op, "op", {}, 0)
	if not Ok then
		return false, Where
	end

	if Measure(Op) > MAX_BYTES then
		return false, OVER
	end

	return true, nil
end

local function IsValueStorable(Value: any): (boolean, string?)
	local Ok, Where = Check(Value, "value", {}, 0)
	if not Ok then
		return false, Where
	end

	if Measure(Value) > MAX_BYTES then
		return false, OVER
	end

	return true, nil
end

return table.freeze({
	Op = IsStorable,
	Value = IsValueStorable,
})
