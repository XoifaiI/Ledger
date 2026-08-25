--!strict
--!optimize 2

--[=[
	Core: What each other half of the store needs first.

	It resolves a key, and it gets the log and the shape that this store folds with.
	Core keeps the log handle against the wrapper that built it, so a store that swaps its backend
	gets a new handle and not one that points at the old datastore.
	A tally puts its shard number after a mark in the key. A key of a game may not hold that mark.

	Return type: A table with Mark, KeyFor, KeyIssue, Live, Resolve, ExpectPlayers, ExpectBalance, Records, Format, Fold, ReadRecord, ValidId and MAX_KEY.
	Example usage:
		local Core = require("./Core")
		local Key = self:Resolve(1, "Peek")
--]=]

local Contract = require("../Contract/Op")
local Tally = require("../Feature/Tally")
local Mark = require("../Encode/Mark")
local Log = require("../Record/Log")
local Shape = require("../Record/Shape")
local LogTypes = require("../Record/Types")
local Store = require("./Class")
local Types = require("./Types")

type Record = Contract.Record<any>
type KeyLike = Contract.KeyLike
type Store = Types.Store

local MAX_KEY = 50

local function ValidId(UserId: any): boolean
	return type(UserId) == "number" and UserId == UserId // 1 and UserId > 0 and UserId < math.huge
end

function Store.Mark(self: Store, Key: string): string
	return Mark.Of(self.Wrapper.Name, Key)
end

function Store.KeyFor(self: Store, Value: any): string?
	if self.Keys == "Player" then
		return if ValidId(Value) then tostring(Value) else nil
	end
	return if type(Value) == "string" and #Value > 0 and #Value <= MAX_KEY and utf8.len(Value) ~= nil and string.find(Value, Tally.PART, 1, true) == nil then Value else nil
end

function Store.KeyIssue(self: Store): string
	return if self.Keys == "Player" then "a positive integer UserId" else `a key string of 1 to {MAX_KEY} characters, without '{Tally.PART}' in it`
end

function Store.Live(self: Store, What: string)
	assert(not self.Closed, `{What} was called on '{self.Options.Name}' after it was destroyed, build a new store with Ledger.New`)
end

function Store.Resolve(self: Store, Key: KeyLike, What: string): string
	self:Live(What)
	local Resolved = self:KeyFor(Key)
	assert(Resolved, `{What} needs {self:KeyIssue()}, got {typeof(Key)}`)
	return Resolved
end

function Store.ExpectPlayers(self: Store, What: string)
	self:Live(What)
	assert(self.Keys == "Player", `{What} is for player stores, '{self.Options.Name}' uses string keys`)
end

function Store.ExpectBalance(self: Store, What: string)
	assert(self.Options.Balance, `{What} needs the store to name a Balance field, like Balance = "Gold"`)
end

function Store.Records(self: Store): LogTypes.Log
	local Books = self.Books
	if Books ~= nil and Books.Wrapper == self.Wrapper then
		return Books
	end

	Books = Log.New(self.Wrapper, #self.Migrations, Shape.FloorOf(self.Migrations))
	self.Books = Books
	return Books
end

function Store.Format(self: Store): LogTypes.Shape<any>
	local Shaped = self.Shaped
	if Shaped ~= nil then
		return Shaped
	end

	Shaped = Shape.New(self.Reducer, self.Initial, self.Migrations, self.Handles)
	self.Shaped = Shaped
	return Shaped
end

function Store.Fold(self: Store, Record: Record): any
	return self:Format():Fold(Record)
end

function Store.ReadRecord(self: Store, Key: string): Record
	return self:Records():Read(Key)
end

return table.freeze({
	ValidId = ValidId,
	MAX_KEY = MAX_KEY,
})
