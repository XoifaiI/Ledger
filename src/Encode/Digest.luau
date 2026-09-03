--!strict
--!optimize 2

--[=[

	Digest: Deterministically encodes values and derives short hashes and buckets.

	Canon produces a stable representation of a value, and a buffer goes in by its bytes rather than
	by where it lives. Of hashes that representation into a short identifier. Bucket maps a value
	evenly into a fixed number of buckets, reading the first four bytes of the hash as one big endian
	number, which is a byte swap since a buffer reads the other way round. Both keep a buffer of their
	own rather than making one per call, and neither ever holds a value between calls. Two servers
	given the same input get the same answer, and
	two inputs that differ at all get different answers: a value carries its type, and so does a key
	that is not a string or that reads like one that does. A plain string key is written as it is, so
	every print a build wrote before this rule still reads the same on the next one.

	Return type: A table with Canon, Of and Bucket.
	Example usage:
		local Digest = require("./Digest")
		local Id = Digest.Of(Digest.Canon(Terms))
--]=]

local EncodingService = game:GetService("EncodingService")

local HASH = Enum.HashAlgorithm.Blake3
local DIGEST_BYTES = 6
local BUCKET_BYTES = 4

local QUALIFIED = "^%a+:"

local DIGEST = buffer.create(DIGEST_BYTES)
local BUCKET = buffer.create(BUCKET_BYTES)

local function Compare(Left: any, Right: any): boolean
	return tostring(Left) < tostring(Right)
end

local function Named(Key: any): string
	if type(Key) ~= "string" then
		return `{typeof(Key)}:{Key}`
	end
	return if string.find(Key, QUALIFIED) ~= nil then `string:{Key}` else Key
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
		table.insert(Parts, `{Named(Key)}={Canon(Value[Key])}`)
	end

	return `({table.concat(Parts, ",")})`
end

local function Hash(Text: string): string
	return EncodingService:ComputeStringHash(Text, HASH)
end

local function Of(Text: string): string
	buffer.writestring(DIGEST, 0, Hash(Text), DIGEST_BYTES)
	return buffer.tostring(EncodingService:Base64Encode(DIGEST))
end

local function Bucket(Text: string, Count: number): number
	buffer.writestring(BUCKET, 0, Hash(Text), BUCKET_BYTES)
	return bit32.byteswap(buffer.readu32(BUCKET, 0)) % Count
end

return table.freeze({
	Canon = Canon,
	Of = Of,
	Bucket = Bucket,
})
