--!strict
--!optimize 2
--!native

--[=[
	Format: the plain numbers of the record's alphabet text (spec/protocols/record/Format.md 1 and 2) on
	buffers: varints below 2^53, fixed numbers, windows and single characters.

	A reader throws through Malformed when the bytes are not what the writer gives, and leaves where it
	stopped undefined. A reader checks representation only. A window is stored as a whole count of the
	WindowUnit the caller gives (Limits.WindowUnit), rounded up.

	Return type: A plain table of functions, FixedNumberWidth (the characters of a fixed number), and the
	Writer and Reader types.
	Example usage:
		local Out = Format.NewWriter(64)
		Format.WriteVarint(Out, 37)
		Format.ToString(Out) --> "hF"
--]=]

local Alphabet = require("./Alphabet")
local Messages = require("../Constants/Messages")
local Record = require("../Constants/Record")

export type Writer = {
	Buffer: buffer,
	Cursor: number,
	Size: number,
}

export type Reader = {
	Bytes: buffer,
	At: number,
}

local Chars = Alphabet.Chars
local Values = Alphabet.Values
local INVALID = Alphabet.INVALID
local AlphabetSize = #Record.Alphabet

local DigitBase = Record.VarintDigitBase
local HasMoreDigits = Record.VarintDigitBase
local TwoDigitLimit = DigitBase * DigitBase
local ThreeDigitLimit = TwoDigitLimit * DigitBase
local VarintLimit = Record.VarintLimit
local VarintWidthMost = math.ceil(math.log(VarintLimit, DigitBase))

local FixedNumberWidth = 3
local FixedNumberLimit = AlphabetSize ^ FixedNumberWidth

local GrowthFactor = 2

local ModuleName = "Format"

local BytesAfterValue = "bytes stand after the end of the value"

local function Malformed(What: string): never
	error(`{ModuleName}: the stored bytes are not what the writer gives, {What}. The decode that reads them gives nil`)
end

local function RequireWholeBelow(Where: string, What: string, Value: number, Limit: number)
	if Value % 1 ~= 0 or Value < 0 or Value >= Limit then
		error(Messages.NotWholeBelow(Where, What, Limit, Value))
	end
end

local function NewWriter(Capacity: number): Writer
	return { Buffer = buffer.create(Capacity), Cursor = 0, Size = Capacity }
end

local function NewReader(Bytes: buffer): Reader
	return { Bytes = Bytes, At = 0 }
end

local function AtEnd(In: Reader): boolean
	return In.At == buffer.len(In.Bytes)
end

local function ToBuffer(Out: Writer): buffer
	local Whole = buffer.create(Out.Cursor)
	buffer.copy(Whole, 0, Out.Buffer, 0, Out.Cursor)
	return Whole
end

local function ToString(Out: Writer): string
	return buffer.readstring(Out.Buffer, 0, Out.Cursor)
end

local function Grow(Out: Writer, Used: number, Extra: number)
	local Size = math.max(Out.Size * GrowthFactor, Used + Extra)
	local Grown = buffer.create(Size)
	buffer.copy(Grown, 0, Out.Buffer, 0, Used)
	Out.Buffer = Grown
	Out.Size = Size
end

local function WriteRaw(Out: Writer, Text: string)
	local Cursor = Out.Cursor
	local Length = #Text
	if Cursor + Length > Out.Size then
		Grow(Out, Cursor, Length)
	end
	buffer.writestring(Out.Buffer, Cursor, Text)
	Out.Cursor = Cursor + Length
end

local function WrittenBefore(Left: Writer, Right: Writer): boolean
	local LeftBuffer = Left.Buffer
	local RightBuffer = Right.Buffer
	local LeftLength = Left.Cursor
	local RightLength = Right.Cursor
	for At = 0, math.min(LeftLength, RightLength) - 1 do
		local LeftByte = buffer.readu8(LeftBuffer, At)
		local RightByte = buffer.readu8(RightBuffer, At)
		if LeftByte ~= RightByte then
			return LeftByte < RightByte
		end
	end
	return LeftLength < RightLength
end

local function VarintWidth(Value: number): number
	local Width = 1
	local Remaining = Value // DigitBase
	while Remaining > 0 do
		Width += 1
		Remaining //= DigitBase
	end
	return Width
end

local function WriteVarint(Out: Writer, Value: number)
	RequireWholeBelow(ModuleName, "a varint", Value, VarintLimit)
	local Cursor = Out.Cursor
	if Cursor + VarintWidthMost > Out.Size then
		Grow(Out, Cursor, VarintWidthMost)
	end
	local Buffer = Out.Buffer
	if Value < DigitBase then
		buffer.writeu8(Buffer, Cursor, buffer.readu8(Chars, Value))
		Out.Cursor = Cursor + 1
	elseif Value < TwoDigitLimit then
		buffer.writeu8(Buffer, Cursor, buffer.readu8(Chars, HasMoreDigits + Value // DigitBase))
		buffer.writeu8(Buffer, Cursor + 1, buffer.readu8(Chars, Value % DigitBase))
		Out.Cursor = Cursor + 2
	elseif Value < ThreeDigitLimit then
		buffer.writeu8(Buffer, Cursor, buffer.readu8(Chars, HasMoreDigits + Value // TwoDigitLimit))
		buffer.writeu8(Buffer, Cursor + 1, buffer.readu8(Chars, HasMoreDigits + Value // DigitBase % DigitBase))
		buffer.writeu8(Buffer, Cursor + 2, buffer.readu8(Chars, Value % DigitBase))
		Out.Cursor = Cursor + 3
	else
		local Width = VarintWidth(Value)
		local Last = Cursor + Width - 1
		buffer.writeu8(Buffer, Last, buffer.readu8(Chars, Value % DigitBase))
		local Remaining = Value // DigitBase
		for At = Last - 1, Cursor, -1 do
			buffer.writeu8(Buffer, At, buffer.readu8(Chars, HasMoreDigits + Remaining % DigitBase))
			Remaining //= DigitBase
		end
		Out.Cursor = Last + 1
	end
end

local function ReadWhole<Result>(Text: string, ReadOne: (In: Reader) -> Result): Result
	local In = NewReader(buffer.fromstring(Text))
	local Result = ReadOne(In)
	if not AtEnd(In) then
		Malformed(BytesAfterValue)
	end
	return Result
end

local function ReadVarint(In: Reader): number
	local Bytes = In.Bytes
	local Size = buffer.len(Bytes)
	local At = In.At
	if At >= Size then
		Malformed(Messages.EndsEarly)
	end
	local First = buffer.readu8(Values, buffer.readu8(Bytes, At))
	At += 1
	if First < HasMoreDigits then
		In.At = At
		return First
	end
	if First == INVALID then
		Malformed(Messages.OutsideAlphabet)
	end
	if First == HasMoreDigits then
		Malformed(Messages.LeadingZeroDigit)
	end

	local Value = First - HasMoreDigits
	while At < Size do
		local Index = buffer.readu8(Values, buffer.readu8(Bytes, At))
		if Index == INVALID then
			Malformed(Messages.OutsideAlphabet)
		end
		At += 1
		Value = Value * DigitBase + Index % DigitBase
		if Value >= VarintLimit then
			Malformed(Messages.PlainVarintTooLarge)
		end
		if Index < HasMoreDigits then
			In.At = At
			return Value
		end
	end
	return Malformed(Messages.EndsEarly)
end

local function WriteFixedNumber(Out: Writer, Value: number)
	RequireWholeBelow(ModuleName, "a fixed number", Value, FixedNumberLimit)
	local Cursor = Out.Cursor
	if Cursor + FixedNumberWidth > Out.Size then
		Grow(Out, Cursor, FixedNumberWidth)
	end
	local Buffer = Out.Buffer
	local Remaining = Value
	for At = Cursor + FixedNumberWidth - 1, Cursor, -1 do
		buffer.writeu8(Buffer, At, buffer.readu8(Chars, Remaining % AlphabetSize))
		Remaining //= AlphabetSize
	end
	Out.Cursor = Cursor + FixedNumberWidth
end

local function ReadFixedNumber(In: Reader): number
	local Bytes = In.Bytes
	local At = In.At
	if At + FixedNumberWidth > buffer.len(Bytes) then
		Malformed(Messages.EndsEarly)
	end
	local Value = 0
	for Offset = At, At + FixedNumberWidth - 1 do
		local Index = buffer.readu8(Values, buffer.readu8(Bytes, Offset))
		if Index == INVALID then
			Malformed(Messages.OutsideAlphabet)
		end
		Value = Value * AlphabetSize + Index
	end
	In.At = At + FixedNumberWidth
	return Value
end

local function RoundWindow(Seconds: number, WindowUnit: number): number
	return math.ceil(Seconds / WindowUnit) * WindowUnit
end

local function WriteWindow(Out: Writer, Seconds: number, WindowUnit: number)
	WriteVarint(Out, math.ceil(Seconds / WindowUnit))
end

local function ReadWindow(In: Reader, WindowUnit: number): number
	return ReadVarint(In) * WindowUnit
end

local function WriteCharacter(Out: Writer, Index: number)
	RequireWholeBelow(ModuleName, "a character", Index, AlphabetSize)
	local Cursor = Out.Cursor
	if Cursor == Out.Size then
		Grow(Out, Cursor, 1)
	end
	buffer.writeu8(Out.Buffer, Cursor, buffer.readu8(Chars, Index))
	Out.Cursor = Cursor + 1
end

local function ReadCharacter(In: Reader): number
	local At = In.At
	if At >= buffer.len(In.Bytes) then
		Malformed(Messages.EndsEarly)
	end
	local Index = buffer.readu8(Values, buffer.readu8(In.Bytes, At))
	if Index == INVALID then
		Malformed(Messages.OutsideAlphabet)
	end
	In.At = At + 1
	return Index
end

return {
	FixedNumberWidth = FixedNumberWidth,
	NewWriter = NewWriter,
	NewReader = NewReader,
	AtEnd = AtEnd,
	ToBuffer = ToBuffer,
	ToString = ToString,
	Grow = Grow,
	WriteRaw = WriteRaw,
	WrittenBefore = WrittenBefore,
	ReadWhole = ReadWhole,
	Malformed = Malformed,
	RequireWholeBelow = RequireWholeBelow,
	VarintWidth = VarintWidth,
	WriteVarint = WriteVarint,
	ReadVarint = ReadVarint,
	WriteFixedNumber = WriteFixedNumber,
	ReadFixedNumber = ReadFixedNumber,
	RoundWindow = RoundWindow,
	WriteWindow = WriteWindow,
	ReadWindow = ReadWindow,
	WriteCharacter = WriteCharacter,
	ReadCharacter = ReadCharacter,
}
