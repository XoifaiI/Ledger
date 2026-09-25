--!strict
--!optimize 2

--[=[

	Mark: Puts a store name and a key into one string.

	Each part carries its own length in front of it, so a delimiter byte inside a part cannot break
	the read. Of and Split are the pair for one mark, Pack and Unpack for a list of them. Anything
	that does not carry its length reads back as nothing.

	Cached is the form a MemoryStore key takes. It writes every part's length up front with a
	printable separator, then the parts, since a MemoryStore key holds no byte below a space. A key
	that would pass the cap becomes a digest instead. A digest holds no separator, so it cannot read
	as a mark.

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

local FIELD_HEAD = `^(%d+){FIELD}`
local LIST_HEAD = `^(%d+){LIST}`

local function Read(Text: string, Head: string, At: number): (string?, number)
	local _, Stop, Digits = string.find(Text, Head, At)
	local Size = if Digits ~= nil then tonumber(Digits) else nil
	if Stop == nil or Size == nil or Stop + Size > #Text then
		return nil, At
	end
	return string.sub(Text, Stop + 1, Stop + Size), Stop + Size + 1
end

local function Of(Store: string, Key: string): string
	return #Store .. FIELD .. Store .. Key
end

local function Split(Mark: string): (string?, string?)
	local Store, Rest = Read(Mark, FIELD_HEAD, 1)
	if Store == nil then
		return nil, nil
	end
	return Store, string.sub(Mark, Rest)
end

local function Pack(Parts: { string }): string
	local Pieces: { string } = table.create(#Parts) :: { string }
	for Index, Part in Parts do
		Pieces[Index] = #Part .. LIST .. Part
	end
	return table.concat(Pieces)
end

local function Unpack(Packed: string): { string }
	local Parts: { string } = {}
	local At = 1
	while At <= #Packed do
		local Part, Next = Read(Packed, LIST_HEAD, At)
		if Part == nil then
			return {}
		end
		table.insert(Parts, Part)
		At = Next
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
