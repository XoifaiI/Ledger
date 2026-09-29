--!strict
--!optimize 2
--!native

--[=[

	Reader: Reads what Writer wrote, and refuses any text Writer would not write.

	Each function reads the next value from the book and moves past it. A character outside the
	alphabet, a book that ends early, a number past its range or in a form Writer never makes, and a
	name in the wrong form all raise an error that names the character.

	Label reads what Writer.Label wrote, told by its caller whether it is base64.

	Return type: A table with New, Var, Signed, Wide, Fixed, Name, Label and Done.
	Example usage:
		local Reader = require("./Reader")
		local Book = Reader.New(Text)
		local Count = Reader.Var(Book)
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
local VAR_HIGH = 2 ^ 18
local SIGNED_HIGH = 2 ^ 17
local MAX_DIGITS = 17
local NAME_PATTERN = "^[%w_%-]*$"

local function Fail(At: number, Reason: string): never
	error(`Reader: character {At + 1} of the book is {Reason}`, 0)
end

local function TakeLong(Book: Reader): (number, number)
	local Buffer, Cursor, Length = Book.Buffer, Book.Cursor, Book.Length
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
		local Last = Value >= 32
		if Last then
			Value -= 32
			if Value == 0 and Index > 0 then
				Fail(Cursor, "a number that ends in a zero")
			end
		end
		if Index < 7 then
			Low += Value * Scale
		else
			High += Value * Scale
		end
		Scale = if Index == 6 then 1 else Scale * 32
		Cursor += 1
		Index += 1
		if Last then
			Book.Cursor = Cursor
			return High, Low
		end
	end
end

local function Take(Book: Reader): (number, number)
	local Buffer, Cursor, Length = Book.Buffer, Book.Cursor, Book.Length
	if Cursor + 1 < Length then
		local First = buffer.readu8(VALUES, buffer.readu8(Buffer, Cursor))
		if First >= 32 and First < 64 then
			Book.Cursor = Cursor + 1
			return 0, First - 32
		end
		local Second = buffer.readu8(VALUES, buffer.readu8(Buffer, Cursor + 1))
		if First < 32 and Second > 32 and Second < 64 then
			Book.Cursor = Cursor + 2
			return 0, First + (Second - 32) * 32
		end
	elseif Cursor < Length then
		local First = buffer.readu8(VALUES, buffer.readu8(Buffer, Cursor))
		if First >= 32 and First < 64 then
			Book.Cursor = Cursor + 1
			return 0, First - 32
		end
	end
	return TakeLong(Book)
end

local function New(Text: string): Reader
	return { Buffer = buffer.fromstring(Text), Cursor = 0, Length = #Text }
end

local function Var(Book: Reader): number
	local High, Low = Take(Book)
	if High >= VAR_HIGH then
		Fail(Book.Cursor - 1, "a number past 2^53")
	end
	return High * LIMB + Low
end

local function Wide(Book: Reader): (boolean, number, number)
	local High, Low = Take(Book)
	local Negative = Low % 2 == 1
	Low = Low // 2 + High % 2 * (LIMB / 2)
	High //= 2
	if not Negative then
		return false, High, Low
	end
	Low += 1
	if Low == LIMB then
		High, Low = High + 1, 0
	end
	return true, High, Low
end

local function Signed(Book: Reader): number
	local Start = Book.Cursor
	local High, Low = Take(Book)
	if High < SIGNED_HIGH then
		local Zigzag = High * LIMB + Low
		return if Zigzag % 2 == 0 then Zigzag // 2 else -((Zigzag + 1) // 2)
	end
	Book.Cursor = Start
	local Negative, WideHigh, WideLow = Wide(Book)
	if WideHigh >= VAR_HIGH then
		Fail(Book.Cursor - 1, "a number past 2^53")
	end
	local Size = WideHigh * LIMB + WideLow
	return if Negative then -Size else Size
end

local function Fixed(Book: Reader, Width: number): number
	local Buffer, Cursor = Book.Buffer, Book.Cursor
	if Cursor + Width > Book.Length then
		Fail(Book.Length, "past the end")
	end
	local Value = 0
	for Slot = Cursor, Cursor + Width - 1 do
		local Digit = buffer.readu8(VALUES, buffer.readu8(Buffer, Slot))
		if Digit == INVALID then
			Fail(Slot, "outside the alphabet")
		end
		Value = Value * 64 + Digit
	end
	Book.Cursor = Cursor + Width
	return Value
end

local function TakeText(Book: Reader, Length: number, Base64: boolean): string
	local Buffer, Cursor = Book.Buffer, Book.Cursor
	if Cursor + Length > Book.Length then
		Fail(Book.Length, "a name past the end")
	end
	for Slot = Cursor, Cursor + Length - 1 do
		if buffer.readu8(VALUES, buffer.readu8(Buffer, Slot)) == INVALID then
			Fail(Slot, "outside the alphabet")
		end
	end
	Book.Cursor = Cursor + Length
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
			Bits = Bits * 64 + if Offset < Count then buffer.readu8(VALUES, buffer.readu8(Buffer, Slot + Offset)) else 0
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

local function Name(Book: Reader): string
	local Header = Var(Book)
	return TakeText(Book, Header // 2, Header % 2 == 1)
end

local function Label(Book: Reader, Base64: boolean): string
	return TakeText(Book, Var(Book), Base64)
end

local function Done(Book: Reader): boolean
	return Book.Cursor == Book.Length
end

return table.freeze({
	New = New,
	Var = Var,
	Signed = Signed,
	Wide = Wide,
	Fixed = Fixed,
	Name = Name,
	Label = Label,
	Done = Done,
})
