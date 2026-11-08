--!strict
--!optimize 2
--!native

--[=[
	Json: canonical JSON (spec/protocols/record/Format.md 4, CJ) written straight into a Writer, with no
	whitespace. Size counts the same bytes in any key order. Values the storable guard rejects never reach it.

	A vetted table never changes, so once written its size is kept in Vetted and, under WriteLaidOut, its layout in
	Layouts. WriteLaidOut gives the count of leaves JSONDecode reads back as another value: -0 and a subnormal, both
	written 0. A vetted table keeps its count. SameValue tells zeros of other signs apart, and ChangedKeys uses it, so
	a carried count stays exact. WriteByte, SameValue and DecimalBase are kept local so they inline and fold.

	Return type: A table of the writers, sizes, counts, SameValue and ChangedKeys.
	Example usage:
		Json.CanonicalJson({ b = 2, a = { 1, "x" } }) --> '{"a":[1,"x"],"b":2}'
		Json.Size({ b = 2, a = { 1, "x" } }) --> 17
--]=]

local Escapes = require("./Escapes")
local Float = require("./Float")
local Format = require("./Format")
local Layouts = require("./Layouts")
local Record = require("../Constants/Record")
local Vetted = require("./Vetted")

type Writer = Format.Writer
type Tree = { [unknown]: unknown }

local Grow = Format.Grow
local WriteRaw = Format.WriteRaw
local WriteFloat = Float.WriteFloat
local PutEscape = Escapes.PutEscape
local EscapeWidths = Escapes.Widths

local VarintLimit = Record.VarintLimit
local SmallestNormal = Float.SmallestNormal
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

local PlainBytes = 1
local EscapeBytesMost = Escapes.EscapeBytesMost
local StartBytes = Layouts.StartBytes

local EmptyTableText = "[]"
local EnclosingBytes = #EmptyTableText
local ColonBytes = 1

local IntegerCharactersMost = 1 + math.ceil(math.log10(VarintLimit))

local Scratch = Format.NewWriter(StartCapacity)

local LossyCounts = setmetatable({} :: { [Tree]: number }, { __mode = "k" })

local function WriteByte(Out: Writer, Byte: number)
	local Cursor = Out.Cursor
	if Cursor == Out.Size then
		Grow(Out, Cursor, 1)
	end
	buffer.writeu8(Out.Buffer, Cursor, Byte)
	Out.Cursor = Cursor + 1
end

local function IsPlain(Byte: number): boolean
	return buffer.readu8(EscapeWidths, Byte) == PlainBytes
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
	while Plain < Length and IsPlain(buffer.readu8(Buffer, Start + Plain)) do
		Plain += 1
	end

	local Cursor = Start + Plain
	for Index = Plain + 1, Length do
		local Byte = string.byte(Text, Index)
		if IsPlain(Byte) then
			buffer.writeu8(Buffer, Cursor, Byte)
			Cursor += 1
		else
			local Room = EscapeBytesMost + Length - Index
			if Cursor + Room > Out.Size then
				Grow(Out, Cursor, Room)
				Buffer = Out.Buffer
			end
			Cursor = PutEscape(Buffer, Cursor, Byte)
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

local function IsLossyNumber(Value: number): boolean
	if Value == 0 then
		return 1 / Value < 0
	end
	return math.abs(Value) < SmallestNormal
end

local function WriteNumber(Out: Writer, Value: number): number
	if Value % 1 == 0 and math.abs(Value) < VarintLimit then
		WriteInteger(Out, Value)
	else
		WriteFloat(Out, Value)
	end
	return if IsLossyNumber(Value) then 1 else 0
end

local WriteTable: (Out: Writer, Held: Tree, KeepsLayouts: boolean) -> number

local function WriteValue(Out: Writer, Value: unknown, KeepsLayouts: boolean): number
	if type(Value) == "boolean" then
		WriteRaw(Out, tostring(Value))
		return 0
	end
	if type(Value) == "number" then
		return WriteNumber(Out, Value)
	end
	if type(Value) == "string" then
		WriteString(Out, Value)
		return 0
	end

	local Held = Value :: Tree
	local Start = Out.Cursor
	local Lossy = WriteTable(Out, Held, KeepsLayouts)
	if not Vetted.IsVetted(Held) then
		return Lossy
	end
	if Vetted.SizeOf(Held) == nil then
		Vetted.KeepSize(Held, Out.Cursor - Start)
	end
	if Lossy > 0 then
		LossyCounts[Held] = Lossy
	end
	return Lossy
end

local function NewStarts(Held: Tree, Count: number, KeepsLayouts: boolean): buffer?
	if not KeepsLayouts or not Layouts.KeepsLayout(Count, Vetted.SizeOf(Held) or 0) or not Vetted.IsVetted(Held) then
		return nil
	end
	return buffer.create(Count * StartBytes)
end

local function KeepStarts(Held: Tree, Starts: buffer?, Count: number): ()
	if Starts ~= nil then
		Layouts.Keep(Held, Layouts.New(Starts, Count))
	end
end

function WriteTable(Out: Writer, Held: Tree, KeepsLayouts: boolean): number
	local TableStart = Out.Cursor
	local Lossy = 0
	if Held[1] ~= nil then
		local Count = #Held
		local Starts = NewStarts(Held, Count, KeepsLayouts)
		WriteByte(Out, OpenArrayByte)
		for Index = 1, Count do
			if Index > 1 then
				WriteByte(Out, CommaByte)
			end
			if Starts then
				Layouts.WriteStart(Starts, Index, Out.Cursor - TableStart)
			end
			Lossy += WriteValue(Out, Held[Index], KeepsLayouts)
		end
		WriteByte(Out, CloseArrayByte)
		KeepStarts(Held, Starts, Count)
		return Lossy
	end

	local Keys: { string } = {}
	local Count = 0
	for Key in Held do
		Count += 1
		Keys[Count] = Key :: string
	end
	if Count == 0 then
		WriteRaw(Out, EmptyTableText)
		return Lossy
	end
	table.sort(Keys)
	local Starts = NewStarts(Held, Count, KeepsLayouts)
	WriteByte(Out, OpenObjectByte)
	for Index, Key in Keys do
		if Index > 1 then
			WriteByte(Out, CommaByte)
		end
		if Starts then
			Layouts.WriteStart(Starts, Index, Out.Cursor - TableStart)
		end
		WriteString(Out, Key)
		WriteByte(Out, ColonByte)
		Lossy += WriteValue(Out, Held[Key], KeepsLayouts)
	end
	WriteByte(Out, CloseObjectByte)
	KeepStarts(Held, Starts, Count)
	return Lossy
end

local function StringBytes(Text: string): number
	local Length = #Text
	local Count = EnclosingBytes + Length
	for Index = 1, Length do
		local Byte: number = string.byte(Text, Index)
		Count += buffer.readu8(EscapeWidths, Byte) - PlainBytes
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

local function EntryBytes(Held: Tree, Key: unknown, Bytes: number): number
	if Held[1] ~= nil then
		return Bytes
	end
	return ObjectEntryBytes(Key, Bytes)
end

local function ChangedBytes(OldBytes: number, OldCount: number, Count: number, EntryChange: number): number
	return OldBytes + EntryChange + SeparatorBytes(Count) - SeparatorBytes(OldCount)
end

local function TableBytes(Held: Tree): number
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

	local Held = Value :: Tree
	local Known = Vetted.SizeOf(Held)
	if Known ~= nil then
		return Known
	end
	local Bytes = TableBytes(Held)
	if Vetted.IsVetted(Held) then
		Vetted.KeepSize(Held, Bytes)
	end
	return Bytes
end

local function CanonicalJson(Value: unknown): string
	local Out = Format.NewWriter(StartCapacity)
	WriteValue(Out, Value, false)
	return Format.ToString(Out)
end

local function WriteLaidOut(Out: Writer, Value: unknown): number
	return WriteValue(Out, Value, true)
end

local function Size(Value: unknown): number
	return ValueBytes(Value)
end

local function LossyCount(Held: Tree): number
	return LossyCounts[Held] or 0
end

local function KeepLossy(Held: Tree, Count: number): ()
	if Vetted.IsVetted(Held) then
		LossyCounts[Held] = if Count > 0 then Count else nil
	end
end

local function EntryLossy(Value: unknown): number
	if type(Value) == "table" then
		return LossyCount(Value :: Tree)
	end
	if type(Value) == "number" and IsLossyNumber(Value) then
		return 1
	end
	return 0
end

local function SameValue(Left: unknown, Right: unknown): boolean
	if Left ~= Right then
		return false
	end
	return Left ~= 0 or 1 / (Left :: number) == 1 / (Right :: number)
end

local function ChangedKeys(New: Tree, Old: Tree): ({ unknown }, number)
	local Changed: { unknown } = {}
	local Count = 0
	for Key, Inner in New do
		Count += 1
		local Before = Old[Key]
		if Inner ~= Before or (Inner == 0 and not SameValue(Inner, Before)) then
			table.insert(Changed, Key)
		end
	end
	return Changed, Count
end

return {
	CanonicalJson = CanonicalJson,
	WriteLaidOut = WriteLaidOut,
	WriteString = WriteString,
	Size = Size,
	StringBytes = StringBytes,
	EntryBytes = EntryBytes,
	ChangedBytes = ChangedBytes,
	LossyCount = LossyCount,
	KeepLossy = KeepLossy,
	EntryLossy = EntryLossy,
	SameValue = SameValue,
	ChangedKeys = ChangedKeys,
}
