--!strict
--!optimize 2

--[=[
	Fingerprint: Makes a short mark of what a name was used for.

	Two servers that build the same request get the same mark, because the text is put in one order first.
	A name that is used again for different terms therefore reads as different.

	Bucket spreads a name over a fixed number of slots, so that two servers asked to place the same
	name land on the same one.

	Return type: A table with Canon, Of, Bucket and BYTES.
	Example usage:
		local Fingerprint = require("./Fingerprint")
		local Print = Fingerprint.Of(Fingerprint.Canon(Terms))
--]=]

local EncodingService = game:GetService("EncodingService")

local BYTES = 6
local ALGORITHM = Enum.HashAlgorithm.Blake3

local function Sorter(Left: any, Right: any): boolean
	return tostring(Left) < tostring(Right)
end

local function SortedFields(Value: any): { any }
	local Fields: { any } = {}
	for Field in Value do
		table.insert(Fields, Field)
	end

	table.sort(Fields, Sorter)
	return Fields
end

local function Canon(Value: any): string
	if type(Value) ~= "table" then
		return `{typeof(Value)}:{Value}`
	end

	local Parts: { string } = {}
	for _, Field in SortedFields(Value) do
		table.insert(Parts, `{Field}={Canon(Value[Field])}`)
	end

	return `({table.concat(Parts, ",")})`
end

local function Of(Text: string): string
	local Raw = EncodingService:ComputeStringHash(Text, ALGORITHM)
	return buffer.tostring(EncodingService:Base64Encode(buffer.fromstring(string.sub(Raw, 1, BYTES))))
end

local function Bucket(Text: string, Count: number): number
	return string.byte(EncodingService:ComputeStringHash(Text, ALGORITHM), 1) % Count
end

return table.freeze({
	Canon = Canon,
	Of = Of,
	Bucket = Bucket,
	BYTES = BYTES,
})
