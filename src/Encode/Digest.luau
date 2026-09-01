--!strict
--!optimize 2

--[=[

	Digest: Deterministically encodes values and derives short hashes and buckets.

	Canon produces a stable representation of a value, and a buffer goes in by its bytes rather than
	by where it lives. Of hashes that representation into a short identifier. Bucket maps a value evenly into a fixed number of buckets. Two servers given the same
	input get the same answer.

	Return type: A table with Canon, Of and Bucket.
	Example usage:
		local Digest = require("./Digest")
		local Id = Digest.Of(Digest.Canon(Terms))
--]=]

local EncodingService = game:GetService("EncodingService")

local HASH = Enum.HashAlgorithm.Blake3
local DIGEST_BYTES = 6
local BUCKET_BYTES = 4

local function Compare(Left: any, Right: any): boolean
	return tostring(Left) < tostring(Right)
end

local function Canon(Value: any): string
	if type(Value) == "buffer" then
		return `buffer:{buffer.tostring(EncodingService:Base64Encode(Value))}`
	end
	if type(Value) ~= "table" then
		return `{typeof(Value)}:{Value}`
	end

	local Keys: { any } = {}
	for Key in Value do
		table.insert(Keys, Key)
	end

	table.sort(Keys, Compare)

	local Parts: { string } = table.create(#Keys) :: { string }
	for _, Key in Keys do
		table.insert(Parts, `{Key}={Canon(Value[Key])}`)
	end

	return `({table.concat(Parts, ",")})`
end

local function Hash(Text: string): string
	return EncodingService:ComputeStringHash(Text, HASH)
end

local function Of(Text: string): string
	local Raw = Hash(Text)
	local Bytes = string.sub(Raw, 1, DIGEST_BYTES)

	return buffer.tostring(EncodingService:Base64Encode(buffer.fromstring(Bytes)))
end

local function Bucket(Text: string, Count: number): number
	local Raw = Hash(Text)
	local A, B, C, D = string.byte(Raw, 1, BUCKET_BYTES)

	return (((A * 256 + B) * 256 + C) * 256 + D) % Count
end

return table.freeze({
	Canon = Canon,
	Of = Of,
	Bucket = Bucket,
})
