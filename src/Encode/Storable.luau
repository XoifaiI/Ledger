--!strict
--!optimize 2

--[=[
	Storable: Refuses each value that a datastore cannot hold.

	A value must survive one trip to the datastore and back.
	No gaps in an array, no mix of array keys and string keys, no nan, no loop and no metatable.

	Return type: A table with Op, Value, Structure, Reserved and Bookkeeping.
	Example usage:
		local IsStorable = require("./Storable")
		local Ok, Where = IsStorable.Op(Op)
--]=]

local Limits = require("../Contract/Limits")
local Measure = require("./Measure")

local MAX_DEPTH = Limits.Depth

local RESERVED = "__"
local BOOKKEEPING = "_"

local RESERVED_FIELDS = table.freeze({ "Tx", "TxHome", "TxSticky", "TxAt", "TxGen", "TxTerms", "TxOnly" })

local function IsReservedKind(Kind: string): boolean
	return string.sub(Kind, 1, #RESERVED) == RESERVED
end

local function IsBookkeepingField(Name: string): boolean
	return string.sub(Name, 1, #BOOKKEEPING) == BOOKKEEPING
end

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
	elseif Kind == "boolean" or Kind == "buffer" then
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

local function Fits(Value: any, What: string): (boolean, string?)
	if Measure(Value) > Limits.Op then
		return false, `{What} is larger than the {Limits.Op} byte per op limit`
	end
	return true, nil
end

local function IsStorable(Op: any): (boolean, string?)
	if type(Op) == "table" then
		if type(Op.Kind) == "string" and IsReservedKind(Op.Kind) then
			return false, `kind '{Op.Kind}' uses the {RESERVED} prefix reserved for Ledger's internal ops`
		end
		for _, Named in RESERVED_FIELDS do
			if Op[Named] ~= nil then
				return false, `the {Named} field is reserved for the transaction path`
			end
		end
	end

	local Ok, Where = Check(Op, "op", {}, 0)
	if not Ok then
		return false, Where
	end

	return Fits(Op, "the op")
end

local function IsStructureStorable(Value: any): (boolean, string?)
	local Ok, Where = Check(Value, "value", {}, 0)
	if not Ok then
		return false, Where
	end

	return true, nil
end

local function IsValueStorable(Value: any): (boolean, string?)
	local Ok, Where = IsStructureStorable(Value)
	if not Ok then
		return false, Where
	end

	return Fits(Value, "it")
end

return table.freeze({
	Op = IsStorable,
	Value = IsValueStorable,
	Structure = IsStructureStorable,
	Reserved = IsReservedKind,
	Bookkeeping = IsBookkeepingField,
})
