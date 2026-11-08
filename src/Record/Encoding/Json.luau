--!strict
--!optimize 2
--!native

--[=[
	Json: canonical JSON (spec/protocols/record/Format.md 4, CJ) written straight into a Writer, with no
	whitespace. Size counts the same bytes in any key order. Values the storable guard rejects never reach it.

	A vetted table never changes, so its size and text are kept once known, and a later write copies the text
	whole. Only texts of KeptTextMost bytes or fewer are kept, since a parent's text repeats its children's.
	WriteByte and DecimalBase are kept local so they inline and fold.

	Return type: A table with CanonicalJson, Size, KnownSize, KeepSize, EntryBytes and ChangedBytes.
	Example usage:
		Json.CanonicalJson({ b = 2, a = { 1, "x" } }) --> '{"a":[1,"x"],"b":2}'
		Json.Size({ b = 2, a = { 1, "x" } }) --> 17
--]=]

local Float = require("./Float")
local Format = require("./Format")
local Record = require("../Constants/Record")
local Vetted = require("./Vetted")

type Writer = Format.Writer

local Grow = Format.Grow
local WriteRaw = Format.WriteRaw
local WriteFloat = Float.WriteFloat

local VarintLimit = Record.VarintLimit
local DecimalBase = 10
local StartCapacity = 64

local MinusByte = Record.MinusByte
local ZeroByte = Record.ZeroByte

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

local KeptTextMost = 4096

local EmptyTableText = "[]"
local EnclosingBytes = #EmptyTableText
local ColonBytes = 1

local ModuleName = "Json"
local KeptUnvetted = `{ModuleName}: only a vetted table keeps its size. The caller must vet it first`

local LongestEscape = "\\u0000"
local EscapeBytesMost = #LongestEscape

local IntegerCharactersMost = 1 + math.ceil(math.log10(VarintLimit))

local Scratch = Format.NewWriter(StartCapacity)

local Sizes = setmetatable({} :: { [{ [unknown]: unknown }]: number }, { __mode = "k" })
local Texts = setmetatable({} :: { [{ [unknown]: unknown }]: string }, { __mode = "k" })

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

local function WriteNumber(Out: Writer, Value: number)
	if Value % 1 == 0 and math.abs(Value) < VarintLimit then
		WriteInteger(Out, Value)
	else
		WriteFloat(Out, Value)
	end
end

local WriteTable: (Out: Writer, Held: { [unknown]: unknown }) -> ()

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
	local Kept = Texts[Held]
	if Kept ~= nil then
		WriteRaw(Out, Kept)
		return
	end
	local Start = Out.Cursor
	WriteTable(Out, Held)
	local Bytes = Out.Cursor - Start
	if Bytes <= KeptTextMost and Vetted.IsVetted(Held) then
		Texts[Held] = buffer.readstring(Out.Buffer, Start, Bytes)
	end
end

function WriteTable(Out: Writer, Held: { [unknown]: unknown }): ()
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

local ValueBytes: (Value: unknown) -> number

local function SeparatorBytes(Count: number): number
	return math.max(Count - 1, 0)
end

local function ObjectEntryBytes(Key: unknown, Bytes: number): number
	return StringBytes(Key :: string) + ColonBytes + Bytes
end

local function EntryBytes(Held: { [unknown]: unknown }, Key: unknown, Bytes: number): number
	if Held[1] ~= nil then
		return Bytes
	end
	return ObjectEntryBytes(Key, Bytes)
end

local function ChangedBytes(OldBytes: number, OldCount: number, Count: number, EntryChange: number): number
	return OldBytes + EntryChange + SeparatorBytes(Count) - SeparatorBytes(OldCount)
end

local function TableBytes(Held: { [unknown]: unknown }): number
	if Held[1] ~= nil then
		local Count = EnclosingBytes + SeparatorBytes(#Held)
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
		Count += ObjectEntryBytes(Key, ValueBytes(Field))
	end
	return Count + SeparatorBytes(Fields)
end

function ValueBytes(Value: unknown): number
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
	local Known = Sizes[Held]
	if Known ~= nil then
		return Known
	end
	local Bytes = TableBytes(Held)
	if Vetted.IsVetted(Held) then
		Sizes[Held] = Bytes
	end
	return Bytes
end

local function CanonicalJson(Value: unknown): string
	local Out = Format.NewWriter(StartCapacity)
	WriteValue(Out, Value)
	return Format.ToString(Out)
end

local function Size(Value: unknown): number
	return ValueBytes(Value)
end

local function KnownSize(Held: { [unknown]: unknown }): number?
	return Sizes[Held]
end

local function KeepSize(Held: { [unknown]: unknown }, Bytes: number): ()
	if not Vetted.IsVetted(Held) then
		error(KeptUnvetted)
	end
	Sizes[Held] = Bytes
end

return {
	CanonicalJson = CanonicalJson,
	Size = Size,
	KnownSize = KnownSize,
	KeepSize = KeepSize,
	EntryBytes = EntryBytes,
	ChangedBytes = ChangedBytes,
}
