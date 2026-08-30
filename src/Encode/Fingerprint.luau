--!strict
--!optimize 2

--[=[

	Fingerprint: Makes a short mark of what a name was used for.

	Canon writes a value out in one fixed order, Of hashes that to a short mark, and Bucket spreads a
	name evenly over a fixed number of slots. Two servers given the same input get the same answer.

	Return type: A table with Canon, Of, Bucket and BYTES.
	Example usage:
		local Fingerprint = require("./Fingerprint")
		local Print = Fingerprint.Of(Fingerprint.Canon(Terms))
--]=]

local EncodingService = game:GetService("EncodingService")

local BYTES = 6
local SPREAD = 4
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
	local Raw = EncodingService:ComputeStringHash(Text, ALGORITHM)
	local One, Two, Three, Four = string.byte(Raw, 1, SPREAD)
	return (((One * 256 + Two) * 256 + Three) * 256 + Four) % Count
end

return table.freeze({
	Canon = Canon,
	Of = Of,
	Bucket = Bucket,
	BYTES = BYTES,
})
