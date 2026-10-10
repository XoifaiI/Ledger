--!strict
--!optimize 2
--!native

--[=[
	Json: canonical JSON (spec/protocols/record/Format.md 4, CJ) written straight into a Writer, with no
	whitespace.

	Size counts what CanonicalJson writes, by its rules, in any key order; only a float is written, to scratch.
	Values the storable guard rejects never reach it. It has its own WriteByte since a call through another module
	is not inlined.

	Return type: A table with CanonicalJson and Size.
	Example usage:
		Json.CanonicalJson({ b = 2, a = { 1, "x" } }) --> '{"a":[1,"x"],"b":2}'
		Json.Size({ b = 2, a = { 1, "x" } }) --> 17
--]=]

local Format = require("./Format")
local Record = require("../Constants/Record")

type Writer = Format.Writer

local Grow = Format.Grow
local WriteRaw = Format.WriteRaw

local VarintLimit = Record.VarintLimit
local DecimalBase = 10
local JsonPrecisionMost = 17
local StartCapacity = 64

local MinusByte = string.byte("-")
local PlusByte = string.byte("+")
local ZeroByte = string.byte("0")
local ExponentByte = string.byte("e")

local OpenArrayByte = string.byte("[")
local CloseArrayByte = string.byte("]")
local OpenObjectByte = string.byte("{")
local CloseObjectByte = string.byte("}")
local CommaByte = string.byte(",")
local ColonByte = string.byte(":")

local QuoteByte = string.byte('"')
local BackslashByte = string.byte("\\")
local UnicodeEscapeByte = string.byte("u")
local FirstPrintableByte = string.byte(" ")

local LowerHexDigits = buffer.fromstring("0123456789abcdef")
local HexDigitBits = math.log(buffer.len(LowerHexDigits), 2)
local HexDigitMask = buffer.len(LowerHexDigits) - 1

local EmptyTableText = "[]"
local EnclosingBytes = #EmptyTableText

local LongestEscape = "\\u0000"
local EscapeBytesMost = #LongestEscape

local IntegerCharactersMost = 1 + math.ceil(math.log10(VarintLimit))

local Scratch = Format.NewWriter(StartCapacity)

local function WriteByte(Out: Writer, Byte: number)
	local Cursor = Out.Cursor
	if Cursor == Out.Size then
		Grow(Out, Cursor, 1)
	end
	buffer.writeu8(Out.Buffer, Cursor, Byte)
	Out.Cursor = Cursor + 1
end

local function PutEscape(Buffer: buffer, Cursor: number, Byte: number): number
	buffer.writeu8(Buffer, Cursor, BackslashByte)
	if Byte == QuoteByte or Byte == BackslashByte then
		buffer.writeu8(Buffer, Cursor + 1, Byte)
		return Cursor + 2
	end
	buffer.writeu8(Buffer, Cursor + 1, UnicodeEscapeByte)
	buffer.writeu8(Buffer, Cursor + 2, ZeroByte)
	buffer.writeu8(Buffer, Cursor + 3, ZeroByte)
	buffer.writeu8(Buffer, Cursor + 4, buffer.readu8(LowerHexDigits, bit32.rshift(Byte, HexDigitBits)))
	buffer.writeu8(Buffer, Cursor + 5, buffer.readu8(LowerHexDigits, bit32.band(Byte, HexDigitMask)))
	return Cursor + EscapeBytesMost
end

local function NeedsEscape(Byte: number): boolean
	return Byte < FirstPrintableByte or Byte == QuoteByte or Byte == BackslashByte
end

local function WriteString(Out: Writer, Text: string)
	local Length = #Text
	WriteByte(Out, QuoteByte)
	local Start = Out.Cursor
	if Start + Length > Out.Size then
		Grow(Out, Start, Length)
	end
	local Buffer = Out.Buffer

	buffer.writestring(Buffer, Start, Text)
	local Plain = 0
	while Plain < Length and not NeedsEscape(buffer.readu8(Buffer, Start + Plain)) do
		Plain += 1
	end

	local Cursor = Start + Plain
	for Index = Plain + 1, Length do
		local Byte = string.byte(Text, Index)
		if NeedsEscape(Byte) then
			local Room = EscapeBytesMost + Length - Index
			if Cursor + Room > Out.Size then
				Grow(Out, Cursor, Room)
				Buffer = Out.Buffer
			end
			Cursor = PutEscape(Buffer, Cursor, Byte)
		else
			buffer.writeu8(Buffer, Cursor, Byte)
			Cursor += 1
		end
	end
	Out.Cursor = Cursor
	WriteByte(Out, QuoteByte)
end

local function WriteInteger(Out: Writer, Value: number)
	local Cursor = Out.Cursor
	if Cursor + IntegerCharactersMost > Out.Size then
		Grow(Out, Cursor, IntegerCharactersMost)
	end
	local Buffer = Out.Buffer
	if Value < 0 then
		buffer.writeu8(Buffer, Cursor, MinusByte)
		Cursor += 1
	end
	local Remaining = math.abs(Value)
	local Width = 1
	local Place = DecimalBase
	while Remaining >= Place do
		Width += 1
		Place *= DecimalBase
	end
	for At = Cursor + Width - 1, Cursor, -1 do
		local Higher = Remaining // DecimalBase
		local Digit = Remaining - Higher * DecimalBase
		buffer.writeu8(Buffer, At, ZeroByte + Digit)
		Remaining = Higher
	end
	Out.Cursor = Cursor + Width
end

local function ShortestFloatText(Value: number): string
	local Shortest = ""
	for Precision = 1, JsonPrecisionMost do
		Shortest = string.format(`%.{Precision}g`, Value)
		if tonumber(Shortest) == Value then
			break
		end
	end
	return Shortest
end

local function WriteExponentDigits(Out: Writer, Text: string, From: number)
	local Length = #Text
	local At = From
	if string.byte(Text, At) == PlusByte then
		At += 1
	end
	if string.byte(Text, At) == MinusByte then
		WriteByte(Out, MinusByte)
		At += 1
	end
	while At < Length and string.byte(Text, At) == ZeroByte do
		At += 1
	end
	for Index = At, Length do
		WriteByte(Out, string.byte(Text, Index))
	end
end

local function WriteFloat(Out: Writer, Value: number)
	local Shortest = ShortestFloatText(Value)
	local Length = #Shortest
	local At = 1
	while At <= Length and string.byte(Shortest, At) ~= ExponentByte do
		WriteByte(Out, string.byte(Shortest, At))
		At += 1
	end
	if At <= Length then
		WriteByte(Out, ExponentByte)
		WriteExponentDigits(Out, Shortest, At + 1)
	end
end

local function WriteNumber(Out: Writer, Value: number)
	if Value % 1 == 0 and math.abs(Value) < VarintLimit then
		WriteInteger(Out, Value)
	else
		WriteFloat(Out, Value)
	end
end

local function WriteValue(Out: Writer, Value: unknown)
	if type(Value) == "boolean" then
		WriteRaw(Out, tostring(Value))
		return
	end
	if type(Value) == "number" then
		WriteNumber(Out, Value)
		return
	end
	if type(Value) == "string" then
		WriteString(Out, Value)
		return
	end

	local Held = Value :: { [unknown]: unknown }
	if Held[1] ~= nil then
		WriteByte(Out, OpenArrayByte)
		for Index = 1, #Held do
			if Index > 1 then
				WriteByte(Out, CommaByte)
			end
			WriteValue(Out, Held[Index])
		end
		WriteByte(Out, CloseArrayByte)
		return
	end

	local Keys: { string } = {}
	local Count = 0
	for Key in Held do
		Count += 1
		Keys[Count] = Key :: string
	end
	if Count == 0 then
		WriteRaw(Out, EmptyTableText)
		return
	end
	table.sort(Keys)
	WriteByte(Out, OpenObjectByte)
	for Index, Key in Keys do
		if Index > 1 then
			WriteByte(Out, CommaByte)
		end
		WriteString(Out, Key)
		WriteByte(Out, ColonByte)
		WriteValue(Out, Held[Key])
	end
	WriteByte(Out, CloseObjectByte)
end

local function StringBytes(Text: string): number
	local Length = #Text
	local Count = EnclosingBytes + Length
	for Index = 1, Length do
		local Byte = string.byte(Text, Index)
		if Byte < FirstPrintableByte then
			Count += EscapeBytesMost - 1
		elseif Byte == QuoteByte or Byte == BackslashByte then
			Count += 1
		end
	end
	return Count
end

local function IntegerBytes(Value: number): number
	local Width = 1
	if Value < 0 then
		Width += 1
	end
	local Remaining = math.abs(Value)
	local Place = DecimalBase
	while Remaining >= Place do
		Width += 1
		Place *= DecimalBase
	end
	return Width
end

local function ValueBytes(Value: unknown): number
	if type(Value) == "string" then
		return StringBytes(Value)
	end
	if type(Value) == "number" then
		if Value % 1 == 0 and math.abs(Value) < VarintLimit then
			return IntegerBytes(Value)
		end
		Scratch.Cursor = 0
		WriteFloat(Scratch, Value)
		return Scratch.Cursor
	end
	if type(Value) == "boolean" then
		return #tostring(Value)
	end
	local Held = Value :: { [unknown]: unknown }
	if Held[1] ~= nil then
		local Count = EnclosingBytes + #Held - 1
		for Index = 1, #Held do
			Count += ValueBytes(Held[Index])
		end
		return Count
	end
	if next(Held) == nil then
		return EnclosingBytes
	end
	local Count = EnclosingBytes
	local Fields = 0
	for Key, Field in Held do
		Fields += 1
		Count += StringBytes(Key :: string) + 1 + ValueBytes(Field)
	end
	return Count + Fields - 1
end

local function CanonicalJson(Value: unknown): string
	local Out = Format.NewWriter(StartCapacity)
	WriteValue(Out, Value)
	return Format.ToString(Out)
end

local function Size(Value: unknown): number
	return ValueBytes(Value)
end

return {
	CanonicalJson = CanonicalJson,
	Size = Size,
}
