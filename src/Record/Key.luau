--!strict
--!optimize 2

--[=[

	Key: What a key holds, read once.

	This is the one place Ledger asks what shape a stored value has. Read gives back the book and
	the state of a record, nothing at all for a key that holds no value, or the reason every op on it
	stops: Missing for an erase in progress, Behind for a book a newer build wrote, and Corrupt with
	what was wrong for anything else. Store gives back the value a write stores.

	Return type: A table with Read and Store.
	Example usage:
		local Key = require("./Key")
		local Record, State, Why = Key.Read(Current)
--]=]

local Book = require("./Book")
local Types = require("./Types")

type Book = Book.Book
type Why = Types.Why

export type Stored = {
	s: { [string]: any },
	b: string,
}

local Why = Types.Why

local function Read(Current: unknown): (Book?, { [string]: any }?, Why?, string?)
	if Current == nil then
		return nil, nil, nil, nil
	end
	if type(Current) ~= "table" then
		return nil, nil, Why.Corrupt, `the key holds a {typeof(Current)}`
	end
	local Value = Current :: { [string]: unknown }
	if Value.z ~= nil then
		return nil, nil, Why.Missing, nil
	end
	local Text, State = Value.b, Value.s
	if type(Text) ~= "string" or type(State) ~= "table" then
		return nil, nil, Why.Corrupt, "the key has no state or no book"
	end
	local Format = Book.Version(Text)
	if Format and Format > Book.FORMAT then
		return nil, nil, Why.Behind, nil
	end
	local Record, Detail = Book.Decode(Text)
	if Record == nil then
		return nil, nil, Why.Corrupt, Detail
	end
	return Record, State :: { [string]: any }, nil, nil
end

local function Store(State: { [string]: any }, Record: Book, Now: number): Stored
	return { s = State, b = Book.Encode(Record, Now) }
end

return table.freeze({
	Read = Read,
	Store = Store,
})
