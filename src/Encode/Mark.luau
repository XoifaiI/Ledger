--!strict
--!optimize 2

--[=[

	Mark: Puts a store name and a key into one string.

	Each part carries its own length in front of it, so a delimiter byte inside a part cannot break
	the read. Of and Split are the pair for one mark, Pack and Unpack for a list of them. Anything
	that does not carry its length reads back as nothing. Cached is the form a MemoryStore key takes:
	every part's length up front with a printable separator, since a MemoryStore key holds no byte
	below a space, then the parts, and a digest once it would pass the cap. A digest holds no
	separator, so it cannot read as a mark.

	Return type: A table with Of, Split, Pack, Unpack and Cached.
	Example usage:
		local Mark = require("./Mark")
		local Held = Mark.Of("Players", "1")
		local Store, Key = Mark.Split(Held)
--]=]

local MemoryStore = require("../Core/Constants/MemoryStore")
local Digest = require("./Digest")

local FIELD = "\0"
local LIST = "\1"
local CACHE = ":"

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

local function Digits(Text: string, At: number, Length: number): (number, number)
	local Index = At
	local Count = 0

	while Index <= Length do
		local Byte = string.byte(Text, Index) :: number
		if Byte < ZERO or Byte > NINE then
			break
		end

		Count = Count * 10 + Byte - ZERO
		Index += 1
	end

	return Count, Index
end

local function Of(Store: string, Key: string): string
	local Size = #Store
	local Head = FIELD_HEADS[Size + 1]
	local Front = if Head ~= nil then Head else tostring(Size) .. FIELD

	return Front .. Store .. Key
end

local function Split(Mark: string): (string?, string?)
	local Length = #Mark
	local Count, Index = Digits(Mark, 1, Length)

	if Index == 1 or string.byte(Mark, Index) ~= 0 or Index + Count > Length then
		return nil, nil
	end

	return string.sub(Mark, Index + 1, Index + Count), string.sub(Mark, Index + Count + 1)
end

local function Pack(Parts: { string }): string
	local Total = #Parts
	local Pieces: { string } = table.create(Total * 2) :: { [number]: string }
	local Cursor = 0

	for Index = 1, Total do
		local Part = Parts[Index]
		local Size = #Part
		local Head = LIST_HEADS[Size + 1]
		local Front = if Head ~= nil then Head else tostring(Size) .. LIST
		Pieces[Cursor + 1] = Front
		Pieces[Cursor + 2] = Part
		Cursor += 2
	end

	return table.concat(Pieces)
end

local function Unpack(Packed: string): { string }
	local Length = #Packed
	local Parts: { string } = {}
	local Found = 0
	local At = 1

	while At <= Length do
		local Count, Index = Digits(Packed, At, Length)

		if Index == At or string.byte(Packed, Index) ~= 1 or Index + Count > Length then
			return {}
		end

		Found += 1
		Parts[Found] = string.sub(Packed, Index + 1, Index + Count)
		At = Index + Count + 1
	end

	return Parts
end

local function Cached(Parts: { string }): string
	local Heads: { string } = table.create(#Parts) :: { string }
	for Index, Part in Parts do
		Heads[Index] = `{#Part}`
	end

	local Held = `{table.concat(Heads, CACHE)}{CACHE}{table.concat(Parts)}`
	if #Held <= MemoryStore.MAX_KEY then
		return Held
	end
	return Digest.Of(Held)
end

return table.freeze({
	Of = Of,
	Split = Split,
	Pack = Pack,
	Unpack = Unpack,
	Cached = Cached,
})
