--!strict
--!optimize 2
--!native

--[=[

	Value: Checks a game's value and counts the bytes it takes as json.

	Check walks the value once. It gives back the bytes, or nil and where the value cannot be stored:
	nan or inf, a string or a key that is not utf8, a key that is not a string or a whole number from
	1, a table that mixes the two or leaves a gap, a metatable, a function or other kind, or nesting
	past MAX_DEPTH, which is also how a table that holds itself shows.

	A count can be high and is never low, whether the encoder writes a number in full or with an
	exponent. A whole number is charged all its digits. A fraction from SMALL up is charged 24 bytes,
	the most one takes either way, and a smaller one what it takes written in full. A buffer is
	charged its raw bytes, or what Compress gives back when the caller has one and the buffer is large
	enough to be worth it.

	Return type: A table with Check and MAX_DEPTH.
	Example usage:
		local Value = require("./Value")
		local Bytes, Where = Value.Check(State)
--]=]

local MAX_DEPTH = 64
local MAX_EXACT = 2 ^ 53
local FRACTION_BYTES = 24
local SMALL = 1e-5
local BUFFER_WRAP = 35
local COMPRESS_FROM = 4096

local SEVENS = 0x7F7F7F7F
local HIGH = 0x80808080
local PAD = 0x41414141

local EXTRA = buffer.create(256)
for Byte = 0, 31 do
	buffer.writeu8(EXTRA, Byte, 5)
end
for _, Byte in { 8, 9, 10, 12, 13, 34, 92 } do
	buffer.writeu8(EXTRA, Byte, 1)
end

local Scan = buffer.create(1024)

local function ZeroLanes(Word: number): number
	return bit32.band(bit32.bnot(bit32.bor(bit32.band(Word, SEVENS) + SEVENS, Word)), HIGH)
end

local function Dirty(Word: number): number
	return bit32.bor(ZeroLanes(bit32.band(Word, 0xE0E0E0E0)), ZeroLanes(bit32.bxor(Word, 0x22222222)), ZeroLanes(bit32.bxor(Word, 0x5C5C5C5C)))
end

local function StringBytes(Text: string): number
	local Length = #Text
	local Total = Length + 2
	if Length + 4 > buffer.len(Scan) then
		Scan = buffer.create(Length + 4)
	end
	buffer.writestring(Scan, 0, Text)
	buffer.writeu32(Scan, Length, PAD)
	for Offset = 0, Length - 1, 4 do
		if Dirty(buffer.readu32(Scan, Offset)) == 0 then
			continue
		end
		for Index = Offset, math.min(Offset + 3, Length - 1) do
			Total += buffer.readu8(EXTRA, buffer.readu8(Scan, Index))
		end
	end
	return Total
end

local function NumberBytes(Number: number): number
	local Sign = if Number < 0 or (Number == 0 and 1 / Number < 0) then 1 else 0
	local Size = math.abs(Number)
	if Number ~= Number // 1 then
		return if Size >= SMALL then FRACTION_BYTES else Sign + 19 - math.floor(math.log10(Size))
	end
	if Size >= MAX_EXACT then
		return Sign + math.floor(math.log10(Size)) + 2
	end
	local Digits, Limit = 1, 10
	while Size >= Limit do
		Digits += 1
		Limit *= 10
	end
	return Sign + Digits
end

local function BufferBytes(Bytes: buffer, Compress: ((Bytes: buffer) -> number)?): number
	local Stored = buffer.len(Bytes)
	if Compress and Stored >= COMPRESS_FROM then
		Stored = math.min(Stored, Compress(Bytes))
	end
	return BUFFER_WRAP + 4 * ((Stored + 2) // 3)
end

local function Walk(Item: unknown, Depth: number, Compress: ((Bytes: buffer) -> number)?): (number, string?)
	local Kind = type(Item)
	if Kind == "number" then
		local Number = Item :: number
		if Number ~= Number or Number == math.huge or Number == -math.huge then
			return 0, " is nan or inf"
		end
		return NumberBytes(Number), nil
	elseif Kind == "string" then
		if utf8.len(Item :: string) == nil then
			return 0, " is not valid utf8"
		end
		return StringBytes(Item :: string), nil
	elseif Kind == "boolean" then
		return if Item then 4 else 5, nil
	elseif Kind == "buffer" then
		return BufferBytes(Item :: buffer, Compress), nil
	elseif Kind ~= "table" then
		return 0, ` is a {typeof(Item)}`
	elseif Depth >= MAX_DEPTH then
		return 0, ` nests deeper than {MAX_DEPTH}, or holds itself`
	elseif getmetatable(Item :: any) ~= nil then
		return 0, " has a metatable"
	end

	local Total, Count, Last, Keys = 2, 0, 0, "None"
	for Key, Inner in Item :: { [unknown]: unknown } do
		if type(Key) == "string" then
			if Keys == "Array" then
				return 0, " mixes array and string keys"
			elseif utf8.len(Key) == nil then
				return 0, " has a key that is not valid utf8"
			end
			Keys = "Map"
			Total += StringBytes(Key) + 1
		elseif type(Key) == "number" and Key >= 1 and Key % 1 == 0 then
			if Keys == "Map" then
				return 0, " mixes array and string keys"
			end
			Keys = "Array"
			Last = math.max(Last, Key)
		else
			return 0, ` has the key {tostring(Key)}, which is not a string or a whole number from 1`
		end
		local Bytes, Where = Walk(Inner, Depth + 1, Compress)
		if Where then
			return 0, (if type(Key) == "string" then `.{Key}` else `[{Key}]`) .. Where
		end
		Total += Bytes + 1
		Count += 1
	end
	if Last > Count then
		return 0, " is an array with a gap"
	end
	return if Count > 0 then Total - 1 else Total, nil
end

local function Check(Item: unknown, Compress: ((Bytes: buffer) -> number)?): (number?, string?)
	local Bytes, Where = Walk(Item, 0, Compress)
	if Where then
		return nil, `value{Where}`
	end
	return Bytes, nil
end

return table.freeze({
	Check = Check,
	MAX_DEPTH = MAX_DEPTH,
})
