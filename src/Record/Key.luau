--!strict
--!optimize 2

--[=[

	Key: Logic. What a key holds.

	Spec: record 2.1; cuts 3.4 and 3.5.

	Read gives back the book, the state, the post diff of an exclusive mark, and the state a Reset
	was given. It gives nil for an empty key. Else it gives why every op stops: Missing for a seal,
	Behind for a newer format, and Corrupt otherwise. Seal gives back the seal a key holds in place
	of its value, or nil. Store gives back the value to write, and Sealed the value that holds a
	seal.

	Return type: A table with Read, Seal, Store and Sealed. The type is Found.
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
	read Given: State?,
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
	local Text, State, Post, Given = Value.b, Value.s, Value.p, Value.r
	if Value.z ~= nil then
		return Why.Missing
	elseif type(Text) ~= "string" or type(State) ~= "table" or not Changes(Post) or (Given ~= nil and type(Given) ~= "table") then
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
	return { Book = Record, State = State :: State, Post = Post :: { Diff.Change }?, Given = Given :: State? }
end

function Key.Seal(Current: unknown): Book.Seal?
	if type(Current) ~= "table" then
		return nil
	end
	local Text = (Current :: { [string]: unknown }).z
	return if type(Text) == "string" then Book.DecodeSeal(Text) else nil
end

function Key.Store(State: State, Record: Book, Now: number, Post: { Diff.Change }?, Given: State?): Types.Stored
	return { s = State, b = Record:Encode(Now), p = Post, r = Given }
end

function Key.Sealed(Seal: Book.Seal): Types.Stored
	return { z = Book.EncodeSeal(Seal) }
end

return Key
