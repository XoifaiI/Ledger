--!strict
--!optimize 2

--[=[

	Shared: What each other half of the store needs first.

	Resolving a key and saying what a key may look like, the log and the schema this store folds with,
	the request budget, and the six plain functions the sweep sees a store as. The log handle is kept
	against the wrapper that built it.

	Return type: An empty table. It writes Mark, KeyFor, KeyIssue, Live, Resolve, ExpectPlayers, ExpectBalance, Affords, TxAffords, Swept, Records, Format, Fold and ReadRecord onto the class.
	Example usage:
		local Shared = require("./Shared")
		local Key = self:Resolve(1, "Peek")
--]=]

local Shapes = require("../Core/Shapes")
local Shards = require("../Core/Constants/Shards")
local Datastore = require("../Core/Constants/Datastore")
local Mark = require("../Encode/Mark")
local Log = require("../Record/Log")
local Schema = require("../Record/Schema")
local LogTypes = require("../Record/Types")
local Store = require("./Class")
local Types = require("./Types")

type Record = Shapes.Record<any>
type KeyLike = Shapes.KeyLike
type Store = Types.Store<any>

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
	return if type(Value) == "string" and #Value > 0 and #Value <= Datastore.MAX_KEY and utf8.len(Value) ~= nil and string.find(Value, Shards.PART, 1, true) == nil then Value else nil
end

function Store.KeyIssue(self: Store): string
	return if self.Keys == "Player" then "a positive integer UserId" else `a key string of 1 to {Datastore.MAX_KEY} characters, without '{Shards.PART}' in it`
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

function Store.Affords(self: Store, Kind: Enum.DataStoreRequestType, Floor: number): boolean
	return self.Wrapper:Budget(Kind) >= Floor
end

function Store.TxAffords(self: Store, Kind: Enum.DataStoreRequestType, Floor: number): boolean
	return self.TxWrapper:Budget(Kind) >= Floor
end

function Store.Swept(self: Store): Types.Swept
	local Held = self.Sweeping
	if Held ~= nil then
		return Held
	end

	Held = table.freeze({
		Mark = function(Key: string): string
			return self:Mark(Key)
		end,
		Affords = function(Kind: Enum.DataStoreRequestType, Floor: number): boolean
			return self:Affords(Kind, Floor)
		end,
		TxAffords = function(Kind: Enum.DataStoreRequestType, Floor: number): boolean
			return self:TxAffords(Kind, Floor)
		end,
		Repair = function(Key: string): (boolean, boolean)
			return self:Repair(Key)
		end,
		ReapMarkers = function(): number
			return self:ReapMarkers()
		end,
		Claim = function(Key: string, Ttl: number): Types.Claimed
			return self:Claim(Mark.Cached({ "sweep", self.Wrapper.Name, Key }), Ttl)
		end,
	})
	self.Sweeping = Held
	return Held
end

function Store.Records(self: Store): LogTypes.Log
	local Books = self.Books
	if Books ~= nil and Books.Wrapper == self.Wrapper then
		return Books
	end

	Books = Log.New(self.Wrapper, #self.Migrations, Schema.FloorOf(self.Migrations))
	self.Books = Books
	return Books
end

function Store.Format(self: Store): LogTypes.Shape<any>
	local Shaped = self.Shaped
	if Shaped ~= nil then
		return Shaped
	end

	Shaped = Schema.New(self.Reducer, self.Initial, self.Migrations, self.Handles)
	self.Shaped = Shaped
	return Shaped
end

function Store.Fold(self: Store, Record: Record): any
	return self:Format():Fold(Record)
end

function Store.ReadRecord(self: Store, Key: string): Record
	return self:Records():Read(Key)
end

return table.freeze({})
