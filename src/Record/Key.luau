--!strict
--!optimize 2

--[=[

	Key: What a key holds.

	Read gives back the book and the state, nil for an empty key, or why every op stops: Missing for
	an erase in progress, Behind for a newer format, and Corrupt otherwise. Store gives back the value
	to write.

	Return type: A table with Read and Store. The type is Found.
	Example usage:
		local Found = Key.Read(Current)
--]=]

local Book = require("./Book")
local Types = require("./Types")

type Book = Book.Book
type State = { [string]: any }
type Why = Types.Why

export type Found = {
	read Book: Book,
	read State: State,
}

local Why = Types.Why

local Key = {}

function Key.Read(Current: unknown): (Found | Why)?
	if Current == nil then
		return nil
	elseif type(Current) ~= "table" then
		return Why.Corrupt
	end
	local Value = Current :: { [string]: unknown }
	local Text, State = Value.b, Value.s
	if Value.z ~= nil then
		return Why.Missing
	elseif type(Text) ~= "string" or type(State) ~= "table" then
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
	return { Book = Record, State = State :: State }
end

function Key.Store(State: State, Record: Book, Now: number): Types.Stored
	return { s = State, b = Record:Encode(Now) }
end

return Key
