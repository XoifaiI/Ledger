--!strict
--!optimize 2

--[=[

	Hash: Plumbing. The first four bytes of a string's Blake3 hash, little endian. It must never change.

	A seed goes in front of the string.

	Return type: A function that gives back a whole number below 2^32.
	Example usage:
		local Shard = Hash(Name) % Shards
--]=]

local Encoding = require("../Adapters/Encoding")

local function Hash(Text: string, Seed: number?): number
	local Digest = Encoding.Blake3(if Seed then `{Seed}:{Text}` else Text)
	local B0, B1, B2, B3 = string.byte(Digest, 1, 4)
	return B0 + B1 * 0x100 + B2 * 0x10000 + B3 * 0x1000000
end

return Hash
