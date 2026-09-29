--!strict
--!optimize 2
--!native

--[=[

	Alphabet: The 64 characters Ledger writes its bookkeeping in.

	A-Z, a-z, 0-9, - and _ stand for 0 to 63. CHARS maps a value to its byte. VALUES maps a byte to
	its value, or to INVALID for a byte outside the alphabet. LIMB splits a number past 2^53 into two
	parts, High * LIMB + Low.

	Return type: A table with CHARS, VALUES, INVALID and LIMB.
	Example usage:
		local Alphabet = require("./Alphabet")
		local Byte = buffer.readu8(Alphabet.CHARS, 40)
--]=]

local INVALID = 255

local CHARS = buffer.fromstring("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
local VALUES = buffer.create(256)
buffer.fill(VALUES, 0, INVALID)
for Value = 0, 63 do
	buffer.writeu8(VALUES, buffer.readu8(CHARS, Value), Value)
end

return table.freeze({
	CHARS = CHARS,
	VALUES = VALUES,
	INVALID = INVALID,
	LIMB = 2 ^ 35,
})
