--!strict
--!optimize 2

--[=[
	Codec: The json trip that a real datastore puts a value through.

	A buffer has no json form. It goes in and out as base64 under one reserved key, which is what
	a real datastore does with it.
	Only a table that holds that key and nothing else is a buffer. A game field with the same name
	is therefore left alone.

	Return type: A table with Encode, Decode, MAX_VALUE and BLOB.
	Example usage:
		local Codec = require("./Codec")
		local Text = Codec.Encode(Value)
--]=]

local Sizes = require("../Core/Constants/Sizes")

local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")

local BLOB = "__Buffer"

local UNSTORABLE = "value cannot be stored, a datastore only holds json"

local function Packed(Value: any): any
	if type(Value) == "buffer" then
		return { [BLOB] = buffer.tostring(EncodingService:Base64Encode(Value)) }
	end
	if type(Value) ~= "table" then
		return Value
	end

	local Out: { [any]: any } = {}
	for Key, Inner in Value do
		Out[Key] = Packed(Inner)
	end
	return Out
end

local function Unpacked(Value: any): any
	if type(Value) ~= "table" then
		return Value
	end

	local Blob = Value[BLOB]
	if type(Blob) == "string" and next(Value, next(Value) :: any) == nil then
		return EncodingService:Base64Decode(buffer.fromstring(Blob))
	end

	local Out: { [any]: any } = {}
	for Key, Inner in Value do
		Out[Key] = Unpacked(Inner)
	end
	return Out
end

local function Encode(Raw: any): string
	local Value = Packed(Raw)
	local Fine, Text = pcall(function(): string
		return HttpService:JSONEncode(Value)
	end)
	if not Fine or type(Text) ~= "string" then
		error(`Ledger mock: {UNSTORABLE}`, 0)
	end
	if #Text > Sizes.Value then
		error(`Ledger mock: value is larger than the {Sizes.Value} byte limit`, 0)
	end

	local Again, Back = pcall(function(): any
		return HttpService:JSONDecode(Text)
	end)
	assert(Again and Back ~= nil, "the mock encoded a value it cannot decode again, so a round trip would lose it")
	return Text
end

local function Decode(Text: string?): any
	if Text == nil then
		return nil
	end

	local Fine, Value = pcall(function(): any
		return HttpService:JSONDecode(Text :: string)
	end)
	return if Fine then Unpacked(Value) else nil
end

return table.freeze({
	Encode = Encode,
	Decode = Decode,
	MAX_VALUE = Sizes.Value,
	BLOB = BLOB,
})
