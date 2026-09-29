--!strict
--!optimize 2

--[=[

	Hash: Gives a whole number below 2^32 for a string, the same on every server and every build.

	It is the first four bytes of the string's Blake3 hash, read little endian, from EncodingService.
	Fingerprints, shards, parts and levels are all picked from it and stored or agreed on across
	servers, so it must never change. A seed goes in front of the string, so each seed picks apart.

	Return type: A function that gives back a whole number below 2^32.
	Example usage:
		local Hash = require("./Hash")
		local Shard = Hash(Name) % Shards
		local Print = bit32.band(Hash(Canon(Terms)), 0xFFFF)
--]=]

local EncodingService = game:GetService("EncodingService")

local BLAKE3 = Enum.HashAlgorithm.Blake3

local function Hash(Text: string, Seed: number?): number
	local Digest = EncodingService:ComputeStringHash(if Seed then `{Seed}:{Text}` else Text, BLAKE3)
	local B0, B1, B2, B3 = string.byte(Digest, 1, 4)
	return B0 + B1 * 0x100 + B2 * 0x10000 + B3 * 0x1000000
end

return Hash
