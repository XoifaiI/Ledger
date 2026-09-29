--!strict
--!optimize 2
--!native

--[=[

	Writer: Writes Ledger's bookkeeping into a buffer as alphabet text.

	Var writes a whole number below 2^53 as 5 bit digits, lowest first. A digit from the first half of
	the alphabet means more follow, and one from the second half ends the number. Signed zigzags
	first. Wide takes a sign and a magnitude of High * LIMB + Low, up to 2^80. Fixed writes a number
	in a set count of characters and gives back where, and Patch rewrites it there. Name writes a
	string as it is when the alphabet holds it, and as base64url of its bytes otherwise.

	Return type: A table with New, Var, Signed, Wide, Fixed, Patch, Name, Finish and Clear.
	Example usage:
		local Writer = require("./Writer")
		local Book = Writer.New()
		Writer.Var(Book, 300)
		local Text = Writer.Finish(Book)
--]=]

local Alphabet = require("./Alphabet")

export type Writer = {
	Buffer: buffer,
	Cursor: number,
	Size: number,
}

local CHARS = Alphabet.CHARS
local VALUES = Alphabet.VALUES
local INVALID = Alphabet.INVALID
local LIMB = Alphabet.LIMB
local START_SIZE = 256

local function Grow(Book: Writer, Count: number)
	local Size = Book.Size
	local Need = Book.Cursor + Count
	while Size < Need do
		Size *= 2
	end
	local Grown = buffer.create(Size)
	buffer.copy(Grown, 0, Book.Buffer, 0, Book.Cursor)
	Book.Buffer = Grown
	Book.Size = Size
end

local function Put(Book: Writer, Value: number)
	local Cursor = Book.Cursor
	if Cursor + 11 > Book.Size then
		Grow(Book, 11)
	end
	local Buffer = Book.Buffer
	if Value < 32 then
		buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, 32 + Value))
		Book.Cursor = Cursor + 1
	elseif Value < 1024 then
		buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, Value % 32))
		buffer.writeu8(Buffer, Cursor + 1, buffer.readu8(CHARS, 32 + Value // 32))
		Book.Cursor = Cursor + 2
	elseif Value < 32768 then
		buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, Value % 32))
		buffer.writeu8(Buffer, Cursor + 1, buffer.readu8(CHARS, Value // 32 % 32))
		buffer.writeu8(Buffer, Cursor + 2, buffer.readu8(CHARS, 32 + Value // 1024))
		Book.Cursor = Cursor + 3
	else
		while Value >= 32 do
			buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, Value % 32))
			Value //= 32
			Cursor += 1
		end
		buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, 32 + Value))
		Book.Cursor = Cursor + 1
	end
end

local function PutFixed(Buffer: buffer, At: number, Value: number, Width: number)
	if not (Value >= 0 and Value < 64 ^ Width and Value % 1 == 0) then
		error(`Writer: {Value} does not fit in {Width} characters`, 3)
	end
	for Slot = At + Width - 1, At, -1 do
		buffer.writeu8(Buffer, Slot, buffer.readu8(CHARS, Value % 64))
		Value //= 64
	end
end

local function PutBase64(Book: Writer, Value: string)
	local Length = #Value
	local Encoded = (Length * 4 + 2) // 3
	Put(Book, Encoded * 2 + 1)
	local Cursor = Book.Cursor
	if Cursor + Encoded > Book.Size then
		Grow(Book, Encoded)
	end
	local Buffer = Book.Buffer
	for Index = 1, Length, 3 do
		local A, B, C = string.byte(Value, Index, Index + 2)
		local Bits = bit32.bor(bit32.lshift(A, 16), bit32.lshift(B or 0, 8), C or 0)
		buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, bit32.rshift(Bits, 18)))
		buffer.writeu8(Buffer, Cursor + 1, buffer.readu8(CHARS, bit32.band(bit32.rshift(Bits, 12), 63)))
		if B == nil then
			Cursor += 2
			break
		end
		buffer.writeu8(Buffer, Cursor + 2, buffer.readu8(CHARS, bit32.band(bit32.rshift(Bits, 6), 63)))
		if C == nil then
			Cursor += 3
			break
		end
		buffer.writeu8(Buffer, Cursor + 3, buffer.readu8(CHARS, bit32.band(Bits, 63)))
		Cursor += 4
	end
	Book.Cursor = Cursor
end

local function New(): Writer
	return { Buffer = buffer.create(START_SIZE), Cursor = 0, Size = START_SIZE }
end

local function Var(Book: Writer, Value: number)
	if not (Value >= 0 and Value < 2 ^ 53 and Value % 1 == 0) then
		error(`Writer: {Value} is not a whole number from 0 to 2^53 - 1`, 2)
	end
	Put(Book, Value)
end

local function Wide(Book: Writer, Negative: boolean, High: number, Low: number)
	if not (High >= 0 and High < 2 ^ 45 and High % 1 == 0 and Low >= 0 and Low < LIMB and Low % 1 == 0) then
		error("Writer: a wide number needs whole High below 2^45 and Low below LIMB", 2)
	end
	local Sign = 0
	if Negative and (High > 0 or Low > 0) then
		Sign = 1
		if Low == 0 then
			High, Low = High - 1, LIMB - 1
		else
			Low -= 1
		end
	end
	Low = Low * 2 + Sign
	High = High * 2 + Low // LIMB
	Low %= LIMB

	local Cursor = Book.Cursor
	if Cursor + 17 > Book.Size then
		Grow(Book, 17)
	end
	local Buffer = Book.Buffer
	while High > 0 or Low >= 32 do
		buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, Low % 32))
		Low = Low // 32 + High % 32 * (LIMB / 32)
		High //= 32
		Cursor += 1
	end
	buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, 32 + Low))
	Book.Cursor = Cursor + 1
end

local function Signed(Book: Writer, Value: number)
	local Size = math.abs(Value)
	if not (Size < 2 ^ 53 and Value % 1 == 0) then
		error(`Writer: {Value} is not a whole number of size below 2^53`, 2)
	end
	if Size < 2 ^ 52 then
		Put(Book, if Value >= 0 then Size * 2 else Size * 2 - 1)
		return
	end
	Wide(Book, Value < 0, Size // LIMB, Size % LIMB)
end

local function Fixed(Book: Writer, Value: number, Width: number): number
	local At = Book.Cursor
	if At + Width > Book.Size then
		Grow(Book, Width)
	end
	PutFixed(Book.Buffer, At, Value, Width)
	Book.Cursor = At + Width
	return At
end

local function Patch(Book: Writer, At: number, Value: number, Width: number)
	if At < 0 or At + Width > Book.Cursor then
		error(`Writer: a patch at {At} is past what was written`, 2)
	end
	PutFixed(Book.Buffer, At, Value, Width)
end

local function Name(Book: Writer, Value: string)
	local Start = Book.Cursor
	local Length = #Value
	Put(Book, Length * 2)
	local Cursor = Book.Cursor
	if Cursor + Length > Book.Size then
		Grow(Book, Length)
	end
	local Buffer = Book.Buffer
	buffer.writestring(Buffer, Cursor, Value)
	for Slot = Cursor, Cursor + Length - 1 do
		if buffer.readu8(VALUES, buffer.readu8(Buffer, Slot)) == INVALID then
			Book.Cursor = Start
			PutBase64(Book, Value)
			return
		end
	end
	Book.Cursor = Cursor + Length
end

local function Finish(Book: Writer): string
	return buffer.readstring(Book.Buffer, 0, Book.Cursor)
end

local function Clear(Book: Writer)
	Book.Cursor = 0
end

return table.freeze({
	New = New,
	Var = Var,
	Signed = Signed,
	Wide = Wide,
	Fixed = Fixed,
	Patch = Patch,
	Name = Name,
	Finish = Finish,
	Clear = Clear,
})
