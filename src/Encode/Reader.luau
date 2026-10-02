--!strict
--!optimize 2
--!native

--[=[
	Reader: Plumbing. Reads what Writer wrote, and refuses any text Writer would not write.

	Spec: record 2.1.

	A bad character, an early end, a value out of range and a form Writer never makes each raise an
	error, so a decoder that catches the error refuses the whole text. This module checks only the
	form of a value. Book decides whether the value means anything.

	Return type: A table of the readers, and the Reader type.
	Example usage:
		local Count = Reader.Var(Reader.New(Source))
--]=]

local Alphabet = require("./Alphabet")

export type Reader = {
	Buffer: buffer,
	Cursor: number,
	Length: number,
}

local VALUES = Alphabet.VALUES
local INVALID = Alphabet.INVALID
local LIMB = Alphabet.LIMB
local SIZE = Alphabet.SIZE
local DIGIT = Alphabet.DIGIT
local LOW_DIGITS = 7
local VAR_HIGH = 2 ^ 18
local SIGNED_HIGH = 2 ^ 17
local MAX_DIGITS = 17
local NAME_PATTERN = "^[%w_%-]*$"

local function Fail(At: number, Reason: string): never
	error(`Reader: character {At + 1} of the book is {Reason}`, 0)
end

local function TakeLong(Text: Reader): (number, number)
	local Buffer, Cursor, Length = Text.Buffer, Text.Cursor, Text.Length
	local High, Low, Scale, Index = 0, 0, 1, 0
	while true do
		if Index == MAX_DIGITS then
			Fail(Cursor, "a number that does not end")
		end
		if Cursor >= Length then
			Fail(Cursor, "past the end")
		end
		local Value = buffer.readu8(VALUES, buffer.readu8(Buffer, Cursor))
		if Value == INVALID then
			Fail(Cursor, "outside the alphabet")
		end
		local Last = Value >= DIGIT
		if Last then
			Value -= DIGIT
			if Value == 0 and Index > 0 then
				Fail(Cursor, "a number that ends in a zero")
			end
		end
		if Index < LOW_DIGITS then
			Low += Value * Scale
		else
			High += Value * Scale
		end
		Scale = if Index == LOW_DIGITS - 1 then 1 else Scale * DIGIT
		Cursor += 1
		Index += 1
		if Last then
			Text.Cursor = Cursor
			return High, Low
		end
	end
end

local function Take(Text: Reader): (number, number)
	local Buffer, Cursor, Length = Text.Buffer, Text.Cursor, Text.Length
	if Cursor + 1 < Length then
		local First = buffer.readu8(VALUES, buffer.readu8(Buffer, Cursor))
		if First >= DIGIT and First < SIZE then
			Text.Cursor = Cursor + 1
			return 0, First - DIGIT
		end
		local Second = buffer.readu8(VALUES, buffer.readu8(Buffer, Cursor + 1))
		if First < DIGIT and Second > DIGIT and Second < SIZE then
			Text.Cursor = Cursor + 2
			return 0, First + (Second - DIGIT) * DIGIT
		end
	elseif Cursor < Length then
		local First = buffer.readu8(VALUES, buffer.readu8(Buffer, Cursor))
		if First >= DIGIT and First < SIZE then
			Text.Cursor = Cursor + 1
			return 0, First - DIGIT
		end
	end
	return TakeLong(Text)
end

local function New(Source: string): Reader
	return { Buffer = buffer.fromstring(Source), Cursor = 0, Length = #Source }
end

local function Var(Text: Reader): number
	local High, Low = Take(Text)
	if High >= VAR_HIGH then
		Fail(Text.Cursor - 1, "a number past 2^53")
	end
	return High * LIMB + Low
end

local function Wide(Text: Reader): (boolean, number, number)
	local High, Low = Take(Text)
	local Negative = Low % 2 == 1
	Low = Low // 2 + High % 2 * (LIMB / 2)
	High //= 2
	if not Negative then
		return false, High, Low
	end
	Low += 1
	if Low == LIMB then
		High += 1
		Low = 0
	end
	return true, High, Low
end

local function Signed(Text: Reader): number
	local Start = Text.Cursor
	local High, Low = Take(Text)
	if High < SIGNED_HIGH then
		local Zigzag = High * LIMB + Low
		return if Zigzag % 2 == 0 then Zigzag // 2 else -((Zigzag + 1) // 2)
	end
	Text.Cursor = Start
	local Negative, WideHigh, WideLow = Wide(Text)
	if WideHigh >= VAR_HIGH then
		Fail(Text.Cursor - 1, "a number past 2^53")
	end
	local Size = WideHigh * LIMB + WideLow
	return if Negative then -Size else Size
end

local function Fixed(Text: Reader, Width: number): number
	local Buffer, Cursor = Text.Buffer, Text.Cursor
	if Cursor + Width > Text.Length then
		Fail(Text.Length, "past the end")
	end
	local Value = 0
	for Slot = Cursor, Cursor + Width - 1 do
		local Digit = buffer.readu8(VALUES, buffer.readu8(Buffer, Slot))
		if Digit == INVALID then
			Fail(Slot, "outside the alphabet")
		end
		Value = Value * SIZE + Digit
	end
	Text.Cursor = Cursor + Width
	return Value
end

local function TakeText(Text: Reader, Length: number, Base64: boolean): string
	local Buffer, Cursor = Text.Buffer, Text.Cursor
	if Cursor + Length > Text.Length then
		Fail(Text.Length, "a name past the end")
	end
	for Slot = Cursor, Cursor + Length - 1 do
		if buffer.readu8(VALUES, buffer.readu8(Buffer, Slot)) == INVALID then
			Fail(Slot, "outside the alphabet")
		end
	end
	Text.Cursor = Cursor + Length
	if not Base64 then
		return buffer.readstring(Buffer, Cursor, Length)
	end

	if Length % 4 == 1 then
		Fail(Cursor, "a name of a length base64 never has")
	end
	local Out = buffer.create(Length * 3 // 4)
	local Written = 0
	for Slot = Cursor, Cursor + Length - 1, 4 do
		local Count = math.min(Cursor + Length - Slot, 4)
		local Bits = 0
		for Offset = 0, 3 do
			Bits = Bits * SIZE + if Offset < Count then buffer.readu8(VALUES, buffer.readu8(Buffer, Slot + Offset)) else 0
		end
		if Count < 4 and bit32.extract(Bits, 0, 32 - Count * 8) ~= 0 then
			Fail(Slot + Count - 1, "a name with bits past its last byte")
		end
		buffer.writeu8(Out, Written, bit32.rshift(Bits, 16))
		if Count > 2 then
			buffer.writeu8(Out, Written + 1, bit32.band(bit32.rshift(Bits, 8), 255))
		end
		if Count > 3 then
			buffer.writeu8(Out, Written + 2, bit32.band(Bits, 255))
		end
		Written += Count - 1
	end
	local Decoded = buffer.tostring(Out)
	if string.find(Decoded, NAME_PATTERN) then
		Fail(Cursor, "a name in base64 that needs none")
	end
	return Decoded
end

local function Name(Text: Reader): string
	local Header = Var(Text)
	return TakeText(Text, Header // 2, Header % 2 == 1)
end

local function Label(Text: Reader, Base64: boolean): string
	return TakeText(Text, Var(Text), Base64)
end

local function Done(Text: Reader): boolean
	return Text.Cursor == Text.Length
end

return {
	New = New,
	Var = Var,
	Signed = Signed,
	Wide = Wide,
	Fixed = Fixed,
	Name = Name,
	Label = Label,
	Done = Done,
}
