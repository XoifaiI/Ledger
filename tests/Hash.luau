--!strict

--[=[

	Hash: The cases for Encode/Hash.

	The digests are Blake3's published ones. A hash that gives any other value has changed every
	fingerprint and shard already stored.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Hash = require("../src/Encode/Hash")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

Describe("Hash", function()
	Test("a string hashes to the first four bytes of its Blake3 digest, little endian", function()
		Expect(Hash("")).toBe(0xB94913AF)
		Expect(Hash("abc")).toBe(0xACB33764)
	end)

	Test("a seed goes in front of the string", function()
		Expect(Hash("Gold", 7)).toBe(Hash("7:Gold"))
		Expect(Hash("Gold", 7)).never.toBe(Hash("Gold"))
	end)
end)

return nil
