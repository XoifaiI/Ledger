--!strict
--!optimize 2
--!native

--[=[
	Measure: Counts the bytes of a stored value.

	Return type: A function that gives back the number of bytes.
	Example usage:
		local Measure = require("./Measure")
		local Bytes = Measure(State)
--]=]

local MAX_EXACT = 2 ^ 53
local BUFFER_WRAP = 35
local MAX_DEPTH = 64
local FRACTION_MARGIN = 3

local TOO_DEEP = "Measure went deeper than a storable value can nest, so the value is cyclic"

local SEVENS = 0x7F7F7F7F
local HIGH = 0x80808080

local SCRATCH_SIZE = 1024
local SCRATCH_LIMIT = SCRATCH_SIZE - 4
local SCRATCH = buffer.create(SCRATCH_SIZE)
local SAFE_PAD = 0x41414141

local EXTRA = buffer.create(256)
do
	for Byte = 0, 31 do
		buffer.writeu8(EXTRA, Byte, 5)
	end

	for _, Byte in { 8, 9, 10, 12, 13, 34, 92 } do
		buffer.writeu8(EXTRA, Byte, 1)
	end
end

local function ZeroLanes(Word: number): number
	local Low = bit32.band(Word, SEVENS) + SEVENS
	return bit32.band(bit32.bnot(bit32.bor(Low, Word)), HIGH)
end

local function Dirty(Word: number): number
	local Controls = ZeroLanes(bit32.band(Word, 0xE0E0E0E0))
	local Quotes = ZeroLanes(bit32.bxor(Word, 0x22222222))
	local Slashes = ZeroLanes(bit32.bxor(Word, 0x5C5C5C5C))
	return bit32.bor(Controls, Quotes, Slashes)
end

local function StringBytes(Value: string): number
	local Length = #Value
	local Total = Length + 2
	if Length == 0 then
		return Total
	end

	local Bytes = SCRATCH
	if Length <= SCRATCH_LIMIT then
		buffer.writestring(SCRATCH, 0, Value)
		buffer.writeu32(SCRATCH, Length, SAFE_PAD)
	else
		Bytes = buffer.create(Length + 4)
		buffer.writestring(Bytes, 0, Value)
		buffer.writeu32(Bytes, Length, SAFE_PAD)
	end

	local Offset = 0
	local BlockStop = Length - 16
	while Offset <= BlockStop do
		local One = Dirty(buffer.readu32(Bytes, Offset))
		local Two = Dirty(buffer.readu32(Bytes, Offset + 4))
		local Three = Dirty(buffer.readu32(Bytes, Offset + 8))
		local Four = Dirty(buffer.readu32(Bytes, Offset + 12))

		if bit32.bor(bit32.bor(One, Two), bit32.bor(Three, Four)) ~= 0 then
			if One ~= 0 then
				Total += buffer.readu8(EXTRA, buffer.readu8(Bytes, Offset)) + buffer.readu8(EXTRA, buffer.readu8(Bytes, Offset + 1)) + buffer.readu8(EXTRA, buffer.readu8(Bytes, Offset + 2)) + buffer.readu8(
					EXTRA,
					buffer.readu8(Bytes, Offset + 3)
				)
			end

			if Two ~= 0 then
				Total += buffer.readu8(EXTRA, buffer.readu8(Bytes, Offset + 4)) + buffer.readu8(EXTRA, buffer.readu8(Bytes, Offset + 5)) + buffer.readu8(EXTRA, buffer.readu8(Bytes, Offset + 6)) + buffer.readu8(
					EXTRA,
					buffer.readu8(Bytes, Offset + 7)
				)
			end

			if Three ~= 0 then
				Total += buffer.readu8(EXTRA, buffer.readu8(Bytes, Offset + 8)) + buffer.readu8(EXTRA, buffer.readu8(Bytes, Offset + 9)) + buffer.readu8(EXTRA, buffer.readu8(Bytes, Offset + 10)) + buffer.readu8(
					EXTRA,
					buffer.readu8(Bytes, Offset + 11)
				)
			end

			if Four ~= 0 then
				Total += buffer.readu8(EXTRA, buffer.readu8(Bytes, Offset + 12)) + buffer.readu8(EXTRA, buffer.readu8(Bytes, Offset + 13)) + buffer.readu8(EXTRA, buffer.readu8(Bytes, Offset + 14)) + buffer.readu8(
					EXTRA,
					buffer.readu8(Bytes, Offset + 15)
				)
			end
		end

		Offset += 16
	end

	while Offset < Length do
		if Dirty(buffer.readu32(Bytes, Offset)) ~= 0 then
			local Last = Offset + 3
			if Last >= Length then
				Last = Length - 1
			end

			for Index = Offset, Last do
				Total += buffer.readu8(EXTRA, buffer.readu8(Bytes, Index))
			end
		end

		Offset += 4
	end

	return Total
end

local function NumberBytes(Value: number): number
	if Value ~= math.floor(Value) or Value > MAX_EXACT or Value < -MAX_EXACT then
		return #tostring(Value) + FRACTION_MARGIN
	end

	local Rest = Value
	local Digits = 1
	if Rest < 0 then
		Rest = -Rest
		Digits = 2
	end

	if Rest < 100000000 then
		if Rest < 10000 then
			if Rest < 100 then
				return Digits + (if Rest < 10 then 0 else 1)
			end

			return Digits + (if Rest < 1000 then 2 else 3)
		end

		if Rest < 1000000 then
			return Digits + (if Rest < 100000 then 4 else 5)
		end

		return Digits + (if Rest < 10000000 then 6 else 7)
	end

	if Rest < 1000000000000 then
		if Rest < 10000000000 then
			return Digits + (if Rest < 1000000000 then 8 else 9)
		end

		return Digits + (if Rest < 100000000000 then 10 else 11)
	end

	if Rest < 100000000000000 then
		return Digits + (if Rest < 10000000000000 then 12 else 13)
	end

	return Digits + (if Rest < 1000000000000000 then 14 else 15)
end

local function MeasureValue(Value: any, Depth: number): number
	local Kind = type(Value)
	if Kind == "table" then
		local Deeper = Depth + 1
		if Deeper > MAX_DEPTH then
			error(TOO_DEEP)
		end

		local Total = 2
		for Key, Inner in Value do
			if type(Key) == "string" then
				Total += StringBytes(Key) + 1
			end

			local InnerKind = type(Inner)
			if InnerKind == "number" then
				Total += NumberBytes(Inner) + 1
			elseif InnerKind == "string" then
				Total += StringBytes(Inner) + 1
			elseif InnerKind == "boolean" then
				Total += if Inner then 5 else 6
			else
				Total += MeasureValue(Inner, Deeper) + 1
			end
		end

		if Total > 2 then
			Total -= 1
		end

		return Total
	elseif Kind == "string" then
		return StringBytes(Value)
	elseif Kind == "number" then
		return NumberBytes(Value)
	elseif Kind == "boolean" then
		return if Value then 4 else 5
	elseif Kind == "buffer" then
		return BUFFER_WRAP + 4 * ((buffer.len(Value) + 2) // 3)
	end

	return 0
end

local function Measure(Value: any, Depth: number?): number
	return MeasureValue(Value, Depth or 0)
end

return Measure
