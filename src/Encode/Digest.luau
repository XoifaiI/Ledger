--!strict
--!optimize 2

--[=[

	Digest: Deterministically encodes values and derives short hashes and buckets.

	Canon writes a value out the same way every time, and a buffer goes in by its bytes rather than by
	where it lives. Of hashes that text into a short name. Bucket reads the first four bytes of the
	hash as one big endian number, then takes the remainder. A buffer reads the other way round, so
	Bucket swaps the bytes. Neither holds anything between calls.

	Two servers get the same answer from the same input. Two inputs that differ get different
	answers. A value carries its type. So does a key that is not a string, or one that reads like a
	key that carries its type. A string, as a key or a value, has its %, commas, equals signs and
	brackets escaped. One that holds none of them is written as it is.

	Return type: A table with Canon, Of and Bucket.
	Example usage:
		local Digest = require("./Digest")
		local Id = Digest.Of(Digest.Canon(Terms))
--]=]

local EncodingService = game:GetService("EncodingService")

local HASH = Enum.HashAlgorithm.Blake3
local DIGEST_BYTES = 6

local QUALIFIED = "^%a+:"
local FRAMING = "[%%,=()]"
local ESCAPES: { [string]: string } = { ["%"] = "%25", [","] = "%2C", ["="] = "%3D", ["("] = "%28", [")"] = "%29" }

local function Compare(Left: any, Right: any): boolean
	return tostring(Left) < tostring(Right)
end

local function Escaped(Text: string): string
	return (string.gsub(Text, FRAMING, ESCAPES))
end

local function Named(Key: any): string
	if type(Key) ~= "string" then
		return `{typeof(Key)}:{Key}`
	end
	local Text = Escaped(Key)
	return if string.find(Text, QUALIFIED) ~= nil then `string:{Text}` else Text
end

local function Canon(Value: any): string
	if type(Value) == "buffer" then
		return `buffer:{buffer.tostring(EncodingService:Base64Encode(Value))}`
	end
	if type(Value) == "string" then
		return `string:{Escaped(Value)}`
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
	return buffer.tostring(EncodingService:Base64Encode(buffer.fromstring(string.sub(Hash(Text), 1, DIGEST_BYTES))))
end

local function Bucket(Text: string, Count: number): number
	return bit32.byteswap(buffer.readu32(buffer.fromstring(Hash(Text)), 0)) % Count
end

return table.freeze({
	Canon = Canon,
	Of = Of,
	Bucket = Bucket,
})
