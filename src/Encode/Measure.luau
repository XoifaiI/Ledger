--!strict
--!optimize 2
--!native

--[=[
	Measure: Counts the bytes of a stored value.
	
	The count matches the json text that the 4 MB datastore limit applies to.
	A depth of more than 64 levels shows a loop in the value, so this throws.
	
	Return type: A function that gives back the number of bytes.
	Example usage:
		local Measure = require("./Measure")
		local Bytes = Measure(State)
--]=]

local MAX_EXACT = 2 ^ 53
local SEVENS = 0x7F7F7F7F
local HIGH = 0x80808080
local BUFFER_WRAP = 35
local MAX_DEPTH = 64

local TOO_DEEP = "Measure went deeper than a storable value can nest, so the value is cyclic"

local function ZeroLanes(Word: number): number
	local Low = bit32.band(Word, SEVENS) + SEVENS
	return bit32.band(bit32.bnot(bit32.bor(Low, Word)), HIGH)
end

local function CountLanes(Mask: number): number
	return bit32.rshift(Mask, 31)
		+ bit32.band(bit32.rshift(Mask, 23), 1)
		+ bit32.band(bit32.rshift(Mask, 15), 1)
		+ bit32.band(bit32.rshift(Mask, 7), 1)
end

local function ByteExtra(Byte: number): number
	if Byte < 32 then
		return 5
	elseif Byte == 34 or Byte == 92 then
		return 1
	end
	return 0
end

local function StringBytes(Value: string): number
	local Bytes = buffer.fromstring(Value)
	local Length = buffer.len(Bytes)
	local Total = Length + 2

	local Offset = 0
	while Offset + 4 <= Length do
		local Word = buffer.readu32(Bytes, Offset)
		local Controls = ZeroLanes(bit32.band(Word, 0xE0E0E0E0))
		local Quotes = ZeroLanes(bit32.bxor(Word, 0x22222222))
		local Slashes = ZeroLanes(bit32.bxor(Word, 0x5C5C5C5C))
		if bit32.bor(Controls, Quotes, Slashes) ~= 0 then
			Total += 5 * CountLanes(Controls) + CountLanes(bit32.bor(Quotes, Slashes))
		end
		Offset += 4
	end
	for Index = Offset, Length - 1 do
		Total += ByteExtra(buffer.readu8(Bytes, Index))
	end
	return Total
end

local function NumberBytes(Value: number): number
	if Value % 1 ~= 0 or math.abs(Value) > MAX_EXACT then
		return #tostring(Value) + 2
	end

	local Digits = if Value < 0 then 2 else 1
	local Rest = math.abs(Value)
	while Rest >= 10 do
		Rest //= 10
		Digits += 1
	end
	return Digits
end

local function Measure(Value: any, Depth: number?): number
	local Kind = type(Value)
	if Kind == "string" then
		return StringBytes(Value)
	elseif Kind == "number" then
		return NumberBytes(Value)
	elseif Kind == "boolean" then
		return 5
	elseif Kind == "buffer" then
		return BUFFER_WRAP + 4 * ((buffer.len(Value) + 2) // 3)
	elseif Kind ~= "table" then
		return 0
	end

	local Deeper = (Depth or 0) + 1
	assert(Deeper <= MAX_DEPTH, TOO_DEEP)

	local Total = 2
	for Key, Inner in Value do
		if type(Key) == "string" then
			Total += StringBytes(Key) + 1
		end
		Total += Measure(Inner, Deeper) + 1
	end
	return Total
end

return Measure
