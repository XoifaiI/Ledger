--!strict
--!optimize 2

--[=[
	Alphabet: the record's 64 characters as two lookup buffers, the character of each value and the value of
	each byte. It is the base64url alphabet in the same order, so a name is coded straight through these
	buffers.

	Return type: A table with Chars (value to character), Values (byte to value, INVALID for a byte
	outside the alphabet) and INVALID.
	Example usage:
		buffer.readu8(Alphabet.Chars, 37) --> string.byte("l")
--]=]

local Record = require("../Constants/Record")

local INVALID = 255

local Chars = buffer.fromstring(Record.Alphabet)

local Values = buffer.create(2 ^ Record.BitsPerByte)
buffer.fill(Values, 0, INVALID)
for Index = 0, #Record.Alphabet - 1 do
	buffer.writeu8(Values, buffer.readu8(Chars, Index), Index)
end

return {
	Chars = Chars,
	Values = Values,
	INVALID = INVALID,
}
