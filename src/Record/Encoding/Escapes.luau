--!strict
--!optimize 2
--!native

--[=[
	Escapes: how canonical JSON (spec/protocols/record/Format.md 4, CJ) writes each byte of a string, and how a
	written string is read back, so the writer, the sizes and the reader keep one rule.

	A byte below a space is a backslash, u00 and two lowercase hex digits; a quote or a backslash is a backslash and
	itself; every other byte, UTF-8 included, is itself. CompareWritten reads only what this writer writes, starting
	at the string's opening quote, and orders by bytes as table.sort does.

	Return type: A table with Widths, EscapeBytesMost, PutEscape and CompareWritten.
	Example usage:
		buffer.readu8(Escapes.Widths, string.byte("\t")) --> 6
		Escapes.CompareWritten(buffer.fromstring('"a\\"b"'), 0, 'a"b') --> 0
--]=]

local Record = require("../Constants/Record")

local ZeroByte = Record.ZeroByte
local QuoteByte = string.byte('"')
local BackslashByte = string.byte("\\")
local UnicodeEscapeByte = string.byte("u")
local FirstPrintableByte = string.byte(" ")

local UnicodePrefix = "\\u00"
local EscapedAt = 1
local FirstZeroAt = EscapedAt + 1
local SecondZeroAt = FirstZeroAt + 1
local HighHexAt = #UnicodePrefix
local LowHexAt = HighHexAt + 1
local EscapeBytesMost = LowHexAt + 1
local ShortEscapeBytes = EscapedAt + 1
local PlainBytes = 1

local LowerHexDigits = buffer.fromstring("0123456789abcdef")
local HexBase = buffer.len(LowerHexDigits)
local HexDigitBits = math.log(HexBase, 2)
local HexDigitMask = HexBase - 1

local ByteValues = 2 ^ Record.BitsPerByte

local Widths = buffer.create(ByteValues)
for Byte = 0, ByteValues - 1 do
	local Width = PlainBytes
	if Byte < FirstPrintableByte then
		Width = EscapeBytesMost
	elseif Byte == QuoteByte or Byte == BackslashByte then
		Width = ShortEscapeBytes
	end
	buffer.writeu8(Widths, Byte, Width)
end

local HexValues = buffer.create(ByteValues)
for Digit = 0, HexBase - 1 do
	buffer.writeu8(HexValues, buffer.readu8(LowerHexDigits, Digit), Digit)
end

local function PutEscape(Buffer: buffer, Cursor: number, Byte: number): number
	buffer.writeu8(Buffer, Cursor, BackslashByte)
	if buffer.readu8(Widths, Byte) == ShortEscapeBytes then
		buffer.writeu8(Buffer, Cursor + EscapedAt, Byte)
		return Cursor + ShortEscapeBytes
	end
	buffer.writeu8(Buffer, Cursor + EscapedAt, UnicodeEscapeByte)
	buffer.writeu8(Buffer, Cursor + FirstZeroAt, ZeroByte)
	buffer.writeu8(Buffer, Cursor + SecondZeroAt, ZeroByte)
	buffer.writeu8(Buffer, Cursor + HighHexAt, buffer.readu8(LowerHexDigits, bit32.rshift(Byte, HexDigitBits)))
	buffer.writeu8(Buffer, Cursor + LowHexAt, buffer.readu8(LowerHexDigits, bit32.band(Byte, HexDigitMask)))
	return Cursor + EscapeBytesMost
end

local function CompareWritten(Text: buffer, At: number, Key: string): number
	local Cursor = At + 1
	local Index = 1
	local Length = string.len(Key)
	while true do
		local Byte = buffer.readu8(Text, Cursor)
		if Byte == QuoteByte then
			return if Index > Length then 0 else -1
		end
		if Byte ~= BackslashByte then
			Cursor += PlainBytes
		elseif buffer.readu8(Text, Cursor + EscapedAt) == UnicodeEscapeByte then
			local High = buffer.readu8(HexValues, buffer.readu8(Text, Cursor + HighHexAt))
			Byte = High * HexBase + buffer.readu8(HexValues, buffer.readu8(Text, Cursor + LowHexAt))
			Cursor += EscapeBytesMost
		else
			Byte = buffer.readu8(Text, Cursor + EscapedAt)
			Cursor += ShortEscapeBytes
		end
		if Index > Length then
			return 1
		end
		local Wanted = string.byte(Key, Index)
		if Byte ~= Wanted then
			return if Byte < Wanted then -1 else 1
		end
		Index += 1
	end
end

return {
	Widths = Widths,
	EscapeBytesMost = EscapeBytesMost,
	PutEscape = PutEscape,
	CompareWritten = CompareWritten,
}
