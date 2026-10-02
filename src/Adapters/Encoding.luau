--!strict
--!optimize 2

--[=[
	Encoding: Plumbing. The engine's Blake3 hash of a string.

	Return type: A table with Blake3, which gives back the 32 byte digest as a string.
	Example usage:
		local Digest = Encoding.Blake3(Text)
--]=]

local EncodingService = game:GetService("EncodingService")

local BLAKE3 = Enum.HashAlgorithm.Blake3

local Encoding = {}

function Encoding.Blake3(Text: string): string
	return EncodingService:ComputeStringHash(Text, BLAKE3)
end

return Encoding
