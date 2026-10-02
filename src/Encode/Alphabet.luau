--!strict
--!optimize 2
--!native

--[=[
	Alphabet: Plumbing. The 64 characters of Ledger's bookkeeping: A-Z, a-z, 0-9, - and _.

	Spec: record 2.1.

	JSON escapes none of these characters, so the bytes a datastore stores are the encoded bytes. A
	varint digit holds a value below DIGIT, and DIGIT added to it marks the last digit of a number.
	A number past 2^53 is kept as two limbs, High * LIMB + Low.

	Return type: A table of the alphabet's tables and constants.
	Example usage:
		local Byte = buffer.readu8(Alphabet.CHARS, 40)
--]=]

local INVALID = 255
local SIZE = 64
local DIGIT = 32

local CHARS = buffer.fromstring("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
local VALUES = buffer.create(256)
buffer.fill(VALUES, 0, INVALID)
for Value = 0, SIZE - 1 do
	buffer.writeu8(VALUES, buffer.readu8(CHARS, Value), Value)
end

return {
	CHARS = CHARS,
	VALUES = VALUES,
	INVALID = INVALID,
	SIZE = SIZE,
	DIGIT = DIGIT,
	LIMB = 2 ^ 35,
}
