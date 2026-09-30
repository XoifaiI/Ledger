--!strict
--!optimize 2

--[=[

	Key: Logic. What a key holds.

	Spec: record 2.1.

	Read gives back the book, the state and the post diff of an exclusive mark, nil for an empty key,
	or why every op stops: Missing for an erase in progress, Behind for a newer format, and Corrupt
	otherwise. Store gives back the value to write.

	Return type: A table with Read and Store. The type is Found.
	Example usage:
		local Found = Key.Read(Current)
--]=]

local Book = require("./Book")
local Diff = require("./Diff")
local Types = require("./Types")

type Book = Book.Book
type State = { [string]: any }
type Why = Types.Why

export type Found = {
	read Book: Book,
	read State: State,
	read Post: { Diff.Change }?,
}

local Why = Types.Why

local Key = {}

local function Changes(Post: unknown): boolean
	if Post == nil then
		return true
	elseif type(Post) ~= "table" then
		return false
	end
	for _, Each in Post :: { any } do
		if type(Each) ~= "table" or type(Each.k) ~= "table" or #Each.k == 0 then
			return false
		end
	end
	return true
end

function Key.Read(Current: unknown): (Found | Why)?
	if Current == nil then
		return nil
	elseif type(Current) ~= "table" then
		return Why.Corrupt
	end
	local Value = Current :: { [string]: unknown }
	local Text, State, Post = Value.b, Value.s, Value.p
	if Value.z ~= nil then
		return Why.Missing
	elseif type(Text) ~= "string" or type(State) ~= "table" or not Changes(Post) then
		return Why.Corrupt
	end
	local Format = Book.Version(Text)
	if Format and Format > Book.FORMAT then
		return Why.Behind
	end
	local Record = Book.Decode(Text)
	if Record == nil then
		return Why.Corrupt
	end
	return { Book = Record, State = State :: State, Post = Post :: { Diff.Change }? }
end

function Key.Store(State: State, Record: Book, Now: number, Post: { Diff.Change }?): Types.Stored
	return { s = State, b = Record:Encode(Now), p = Post }
end

return Key
