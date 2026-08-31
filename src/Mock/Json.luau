--!strict
--!optimize 2

--[=[

	Json: The json trip a real datastore puts a value through.

	Encode refuses anything json cannot hold and anything over the value cap. A buffer has no json
	form, so it is compressed and goes in and out as base64 under one reserved key, which is what a
	real datastore charges for one. Only a table holding that key and nothing else reads back as a
	buffer.

	Return type: A table with Encode, Decode and MAX_VALUE.
	Example usage:
		local Json = require("./Json")
		local Text = Json.Encode(Value)
--]=]

local Sizes = require("../Core/Constants/Sizes")

local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")

local BLOB = "__Buffer"

local ZSTD = Enum.CompressionAlgorithm.Zstd
local ZSTD_LEVEL = 1

local UNSTORABLE = "value cannot be stored, a datastore only holds json"

local function Packed(Value: any): any
	if type(Value) == "buffer" then
		return { [BLOB] = buffer.tostring(EncodingService:Base64Encode(EncodingService:CompressBuffer(Value, ZSTD, ZSTD_LEVEL))) }
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
		return EncodingService:DecompressBuffer(EncodingService:Base64Decode(buffer.fromstring(Blob)), ZSTD)
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
})
