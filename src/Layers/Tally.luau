--!strict
--!optimize 2

--[=[

	Tally: A total spread over a fixed set of keys.

	Each server writes its own shard and never waits behind another, so a total only goes up and no
	single key knows it. Mine picks this server's shard, Shards names them all, and the running total
	lives in a field of Ledger's own rather than the game's. A summed total is cached under Cache and
	judged by its own At, never by the item's expiry, and while it is stale one server holds a short
	claim on refilling it so the rest answer the stale sum rather than all reading the shards at once.

	Return type: A table with Layered, Bump, Counted, Mine, Shard, Keys, Cache, Read, Fresh and Claimed. The types are Cached, Bucket and Recent.
	Example usage:
		local Tally = require("./Tally")
		local Key = Tally.Shard(Name, Tally.Mine())
--]=]

local Digest = require("../Encode/Digest")
local Ids = require("../Encode/Ids")
local Mark = require("../Encode/Mark")
local Validate = require("../Core/Validate")
local Kinds = require("../Core/Constants/Kinds")
local Shards = require("../Core/Constants/Shards")
local Windows = require("../Core/Constants/Windows")
local Layer = require("./Layer")
local Shapes = require("../Core/Shapes")

type Op = Shapes.Op
type Data = Shapes.Folded

export type Cached = {
	Sum: number,
	At: number,
	Claimed: number?,
}

export type Bucket = {
	Seq: number,
	At: number,
	Amount: number,
}

export type Recent = {
	Sum: number,
	At: number,
	Seen: number,
	Mark: number?,
	OwnAt: number?,
	OwnMark: number?,
	Bumps: { Bucket },
}

local LastNode = ""
local LastShard = 0

local function Counted(State: Data, Field: string): number
	if type(State) ~= "table" then
		return 0
	end

	local Sums = State._Tally
	if Sums == nil or type(Sums[Field]) ~= "number" then
		return 0
	end
	return math.max(Sums[Field], 0)
end

local function Bumping(Data: Data, Op: Op): Data?
	local Field = Op.Field
	local Amount = Validate.Number(Op.Amount)
	if type(Field) ~= "string" or type(Data[Field]) ~= "number" then
		return nil
	end
	if Amount == nil then
		return nil
	end

	local Held = Data._Tally
	local Running = if Held ~= nil and type(Held[Field]) == "number" then Held[Field] else 0

	local Kept: { [string]: number } = if Held ~= nil then table.clone(Held) else {}
	Kept[Field] = Running + Amount

	local Next = table.clone(Data)
	Next._Tally = Kept
	return Next
end

local function Mine(Node: string?): number
	local Home = Node or Ids.Home()
	if Home ~= LastNode then
		LastNode = Home
		LastShard = Digest.Bucket(Home, Shards.SHARDS)
	end
	return LastShard
end

local function Shard(Name: string, Index: number): string
	return `{Name}{Shards.PART}{Index}`
end

local function Keys(Name: string): { string }
	local Keys: { string } = table.create(Shards.SHARDS) :: { string }
	for Index = 1, Shards.SHARDS do
		Keys[Index] = Shard(Name, Index - 1)
	end
	return Keys
end

local function Bump(Field: string, Amount: number): Op
	return { Id = Ids.Fresh(), Kind = Kinds.BUMP, Field = Field, Amount = Amount } :: any
end

local function Cache(Store: string, Name: string, Field: string): string
	return Mark.Cached({ Store, Name, Field })
end

local function Read(Value: any): Cached?
	if type(Value) ~= "table" or type(Value.Sum) ~= "number" or type(Value.At) ~= "number" then
		return nil
	end
	if Value.Claimed ~= nil and type(Value.Claimed) ~= "number" then
		return nil
	end
	return Value
end

local function Fresh(Item: Cached, Now: number): boolean
	return Now - Item.At <= Windows.TALLY_CACHE
end

local function Claimed(Item: Cached, Now: number): boolean
	local At = Item.Claimed
	return At ~= nil and Now - At <= Windows.TALLY_CLAIM
end

local Held: Layer.Layer = {
	Kinds = {
		[Kinds.BUMP] = Bumping,
	},
	Owns = {
		{ Field = Shards.FIELD, Says = "the tally" },
	},
}

local function Layered(_Balance: string?): Layer.Layer?
	return Held
end

return table.freeze({
	Layered = Layered,

	Bump = Bump,
	Counted = Counted,
	Mine = Mine,
	Shard = Shard,
	Keys = Keys,
	Cache = Cache,
	Read = Read,
	Fresh = Fresh,
	Claimed = Claimed,
})
