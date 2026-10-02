--!strict
--!optimize 2
--!native

--[=[
	Value: Plumbing. Checks that a datastore can hold a value, and counts its json bytes.

	Check gives back the bytes, or nil and where the value cannot be stored. The count is never low,
	so a value it passes under a cap is under the cap once stored. A buffer counts its raw bytes, or
	what Compress gives back when there is one.

	Return type: A table with Check.
	Example usage:
		local Bytes, Where = Value.Check(State)
--]=]

local Limits = require("../Core/Constants/Limits")

local MAX_EXACT = 2 ^ 53
local FRACTION_BYTES = 24
local SMALL = 1e-5
local BUFFER_WRAP = 35
local COMPRESS_FROM = 4096
local TRUE_BYTES = 4
local FALSE_BYTES = 5

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
		return if Item then TRUE_BYTES else FALSE_BYTES, nil
	elseif Kind == "buffer" then
		return BufferBytes(Item :: buffer, Compress), nil
	elseif Kind ~= "table" then
		return 0, ` is a {typeof(Item)}`
	elseif Depth >= Limits.DEPTH_MAX then
		return 0, ` nests deeper than {Limits.DEPTH_MAX}, or holds itself`
	elseif getmetatable(Item :: any) ~= nil then
		return 0, " has a metatable"
	end

	local Total, Count, Last, Strings, Numbers = 2, 0, 0, 0, 0
	for Key, Inner in Item :: { [unknown]: unknown } do
		if type(Key) == "string" then
			if Numbers > 0 then
				return 0, " mixes array and string keys"
			elseif utf8.len(Key) == nil then
				return 0, " has a key that is not valid utf8"
			end
			Strings += 1
			Total += StringBytes(Key) + 1
		elseif type(Key) == "number" and Key >= 1 and Key % 1 == 0 then
			if Strings > 0 then
				return 0, " mixes array and string keys"
			end
			Numbers += 1
			Last = math.max(Last, Key)
		else
			return 0, ` has the key {tostring(Key)}, which is not a string or a whole number from 1`
		end
		local Bytes, Where = Walk(Inner, Depth + 1, Compress)
		if Where then
			return 0, if type(Key) == "string" then `.{Key}{Where}` else `[{Key}]{Where}`
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

return {
	Check = Check,
}
