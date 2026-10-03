--!strict
--!optimize 2
--!native

--[=[
	Writer: Plumbing. Writes Ledger's bookkeeping into a buffer as alphabet text.

	A varint is 5 bit digits, lowest first, and a digit from the second half of the alphabet ends it.
	Signed zigzags, and a size from 2^52 on goes through the wide form, which reaches 2^80 with a high
	limb below WIDE_HIGH. A fixed width value can be rewritten in place by Patch, which is how a
	count is written before the items it counts. A name the alphabet cannot hold goes in as base64url
	behind its length and a flag. Label leaves that flag to its caller.

	Return type: A table of the writers, WIDE_HIGH, and the Writer type.
	Example usage:
		Writer.Var(Text, 300)
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
local SIZE = Alphabet.SIZE
local DIGIT = Alphabet.DIGIT
local TWO_DIGIT_LIMIT = DIGIT * DIGIT
local THREE_DIGIT_LIMIT = TWO_DIGIT_LIMIT * DIGIT
local START_SIZE = 256
local WIDE_HIGH = 2 ^ 45
local VAR_DIGITS = 11
local WIDE_DIGITS = 17

local function Grow(Text: Writer, Count: number)
	local Size = Text.Size
	local Need = Text.Cursor + Count
	while Size < Need do
		Size *= 2
	end
	local Grown = buffer.create(Size)
	buffer.copy(Grown, 0, Text.Buffer, 0, Text.Cursor)
	Text.Buffer = Grown
	Text.Size = Size
end

local function Put(Text: Writer, Value: number)
	local Cursor = Text.Cursor
	if Cursor + VAR_DIGITS > Text.Size then
		Grow(Text, VAR_DIGITS)
	end
	local Buffer = Text.Buffer
	if Value < DIGIT then
		buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, DIGIT + Value))
		Text.Cursor = Cursor + 1
	elseif Value < TWO_DIGIT_LIMIT then
		buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, Value % DIGIT))
		buffer.writeu8(Buffer, Cursor + 1, buffer.readu8(CHARS, DIGIT + Value // DIGIT))
		Text.Cursor = Cursor + 2
	elseif Value < THREE_DIGIT_LIMIT then
		buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, Value % DIGIT))
		buffer.writeu8(Buffer, Cursor + 1, buffer.readu8(CHARS, Value // DIGIT % DIGIT))
		buffer.writeu8(Buffer, Cursor + 2, buffer.readu8(CHARS, DIGIT + Value // TWO_DIGIT_LIMIT))
		Text.Cursor = Cursor + 3
	else
		while Value >= DIGIT do
			buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, Value % DIGIT))
			Value //= DIGIT
			Cursor += 1
		end
		buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, DIGIT + Value))
		Text.Cursor = Cursor + 1
	end
end

local function PutFixed(Buffer: buffer, At: number, Value: number, Width: number)
	if not (Value >= 0 and Value < SIZE ^ Width and Value % 1 == 0) then
		error(`Writer: {Value} does not fit in {Width} characters`, 3)
	end
	for Slot = At + Width - 1, At, -1 do
		buffer.writeu8(Buffer, Slot, buffer.readu8(CHARS, Value % SIZE))
		Value //= SIZE
	end
end

local function PutBase64(Text: Writer, Value: string)
	local Length = #Value
	local Encoded = (Length * 4 + 2) // 3
	local Cursor = Text.Cursor
	if Cursor + Encoded > Text.Size then
		Grow(Text, Encoded)
	end
	local Buffer = Text.Buffer
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
	Text.Cursor = Cursor
end

local function New(): Writer
	return { Buffer = buffer.create(START_SIZE), Cursor = 0, Size = START_SIZE }
end

local function Var(Text: Writer, Value: number)
	if not (Value >= 0 and Value < 2 ^ 53 and Value % 1 == 0) then
		error(`Writer: {Value} is not a whole number from 0 to 2^53 - 1`, 2)
	end
	Put(Text, Value)
end

local function Wide(Text: Writer, Negative: boolean, High: number, Low: number)
	if not (High >= 0 and High < WIDE_HIGH and High % 1 == 0 and Low >= 0 and Low < LIMB and Low % 1 == 0) then
		error("Writer: a wide number needs whole High below 2^45 and Low below LIMB", 2)
	end
	local Sign = 0
	if Negative and (High > 0 or Low > 0) then
		Sign = 1
		if Low == 0 then
			High -= 1
			Low = LIMB - 1
		else
			Low -= 1
		end
	end
	Low = Low * 2 + Sign
	High = High * 2 + Low // LIMB
	Low %= LIMB

	local Cursor = Text.Cursor
	if Cursor + WIDE_DIGITS > Text.Size then
		Grow(Text, WIDE_DIGITS)
	end
	local Buffer = Text.Buffer
	while High > 0 or Low >= DIGIT do
		buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, Low % DIGIT))
		Low = Low // DIGIT + High % DIGIT * (LIMB / DIGIT)
		High //= DIGIT
		Cursor += 1
	end
	buffer.writeu8(Buffer, Cursor, buffer.readu8(CHARS, DIGIT + Low))
	Text.Cursor = Cursor + 1
end

local function Signed(Text: Writer, Value: number)
	local Size = math.abs(Value)
	if not (Size < 2 ^ 53 and Value % 1 == 0) then
		error(`Writer: {Value} is not a whole number of size below 2^53`, 2)
	end
	if Size < 2 ^ 52 then
		Put(Text, if Value >= 0 then Size * 2 else Size * 2 - 1)
		return
	end
	Wide(Text, Value < 0, Size // LIMB, Size % LIMB)
end

local function Fixed(Text: Writer, Value: number, Width: number): number
	local At = Text.Cursor
	if At + Width > Text.Size then
		Grow(Text, Width)
	end
	PutFixed(Text.Buffer, At, Value, Width)
	Text.Cursor = At + Width
	return At
end

local function Patch(Text: Writer, At: number, Value: number, Width: number)
	if At < 0 or At + Width > Text.Cursor then
		error(`Writer: a patch at {At} is past what was written`, 2)
	end
	PutFixed(Text.Buffer, At, Value, Width)
end

local function PutText(Text: Writer, Value: string, Flagged: boolean): boolean
	local Start = Text.Cursor
	local Length = #Value
	Put(Text, if Flagged then Length * 2 else Length)
	local Cursor = Text.Cursor
	if Cursor + Length > Text.Size then
		Grow(Text, Length)
	end
	local Buffer = Text.Buffer
	buffer.writestring(Buffer, Cursor, Value)
	for Slot = Cursor, Cursor + Length - 1 do
		if buffer.readu8(VALUES, buffer.readu8(Buffer, Slot)) == INVALID then
			Text.Cursor = Start
			local Encoded = (Length * 4 + 2) // 3
			Put(Text, if Flagged then Encoded * 2 + 1 else Encoded)
			PutBase64(Text, Value)
			return true
		end
	end
	Text.Cursor = Cursor + Length
	return false
end

local function Name(Text: Writer, Value: string)
	PutText(Text, Value, true)
end

local function Label(Text: Writer, Value: string): boolean
	return PutText(Text, Value, false)
end

local function Finish(Text: Writer): string
	return buffer.readstring(Text.Buffer, 0, Text.Cursor)
end

local function Clear(Text: Writer)
	Text.Cursor = 0
end

return {
	New = New,
	Var = Var,
	Signed = Signed,
	Wide = Wide,
	Fixed = Fixed,
	Patch = Patch,
	Name = Name,
	Label = Label,
	Finish = Finish,
	Clear = Clear,
	WIDE_HIGH = WIDE_HIGH,
}
