--!strict
--!optimize 2
--!native

--[=[

	Alphabet: The 64 characters of Ledger's bookkeeping: A-Z, a-z, 0-9, - and _.

	CHARS maps a value to its byte, and VALUES a byte to its value or INVALID. LIMB splits a number
	past 2^53 into High * LIMB + Low.

	Return type: A table with CHARS, VALUES, INVALID and LIMB.
	Example usage:
		local Byte = buffer.readu8(Alphabet.CHARS, 40)
--]=]

local INVALID = 255

local CHARS = buffer.fromstring("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
local VALUES = buffer.create(256)
buffer.fill(VALUES, 0, INVALID)
for Value = 0, 63 do
	buffer.writeu8(VALUES, buffer.readu8(CHARS, Value), Value)
end

return {
	CHARS = CHARS,
	VALUES = VALUES,
	INVALID = INVALID,
	LIMB = 2 ^ 35,
}
