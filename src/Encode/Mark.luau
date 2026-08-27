--!strict
--!optimize 2

--[=[
	Mark: Puts a store name and a key into one string.

	Each part has its length in front of it. A delimiter byte inside a part therefore cannot break the read.
	A part that does not carry its own length is not a mark, and reads back as nothing.

	Lengths up to 255 have their prefix and delimiter already joined in a table, so writing one is a
	lookup and a concat rather than a tostring. Reading walks the digits by byte, which is why nothing
	here cuts a substring just to find out how long the next part is.

	Return type: A table with FIELD, LIST, Of, Split, Pack and Unpack.
	Example usage:
		local Mark = require("./Mark")
		local Held = Mark.Of("Players", "1")
		local Store, Key = Mark.Split(Held)
--]=]

local Fault = require("../Contract/Fault")

local FIELD = "\0"
local LIST = "\1"

local ZERO = 48
local NINE = 57

local CACHED_LENGTHS = 256

local FIELD_HEADS: { string } = table.create(CACHED_LENGTHS) :: { [number]: string }
local LIST_HEADS: { string } = table.create(CACHED_LENGTHS) :: { [number]: string }
for Size = 0, CACHED_LENGTHS - 1 do
	local Text = tostring(Size)
	FIELD_HEADS[Size + 1] = Text .. FIELD
	LIST_HEADS[Size + 1] = Text .. LIST
end

local function Of(Store: string, Key: string): string
	local Size = #Store
	local Head = FIELD_HEADS[Size + 1]
	local Front = if Head ~= nil then Head else tostring(Size) .. FIELD

	local Made = Front .. Store .. Key
	Fault.Holds(string.sub(Made, #Front + 1, #Front + Size) == Store, "a mark cannot read back the store it was built from")
	return Made
end

local function Split(Mark: string): (string?, string?)
	local First = string.byte(Mark, 1)
	if First == nil or First < ZERO or First > NINE then
		return nil, nil
	end

	local Length = #Mark
	local Index = 2
	local Count = First - ZERO

	while Index <= Length do
		local Byte = string.byte(Mark, Index) :: number
		if Byte < ZERO or Byte > NINE then
			break
		end

		Count = Count * 10 + Byte - ZERO
		Index += 1
	end

	if string.byte(Mark, Index) ~= 0 or Index + Count > Length then
		return nil, nil
	end

	return string.sub(Mark, Index + 1, Index + Count), string.sub(Mark, Index + Count + 1)
end

local function Pack(Parts: { string }): string
	local Total = #Parts
	local Pieces: { string } = table.create(Total * 2) :: { [number]: string }
	local Cursor = 0
	local Bytes = 0

	for Index = 1, Total do
		local Part = Parts[Index]
		local Size = #Part
		local Head = LIST_HEADS[Size + 1]
		local Front = if Head ~= nil then Head else tostring(Size) .. LIST
		Pieces[Cursor + 1] = Front
		Pieces[Cursor + 2] = Part
		Cursor += 2
		Bytes += #Front + Size
	end

	local Packed = table.concat(Pieces)
	Fault.Holds(#Packed == Bytes, "packing marks lost bytes, so one of them holds a byte the format cannot carry")
	return Packed
end

local function Unpack(Packed: string): { string }
	local Length = #Packed
	local Parts: { string } = {}
	local Found = 0
	local At = 1

	while At <= Length do
		local Index = At
		local Count = 0

		while Index <= Length do
			local Byte = string.byte(Packed, Index) :: number
			if Byte < ZERO or Byte > NINE then
				break
			end

			Count = Count * 10 + Byte - ZERO
			Index += 1
		end

		if Index == At or string.byte(Packed, Index) ~= 1 or Index + Count > Length then
			return {}
		end

		local Part = string.sub(Packed, Index + 1, Index + Count)
		Fault.Holds(#Part == Count, "unpacking a mark read fewer bytes than its own length said it had")

		Found += 1
		Parts[Found] = Part
		At = Index + Count + 1
	end

	return Parts
end

return table.freeze({
	FIELD = FIELD,
	LIST = LIST,
	Of = Of,
	Split = Split,
	Pack = Pack,
	Unpack = Unpack,
})
