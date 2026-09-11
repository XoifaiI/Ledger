--!strict
--!optimize 2

--[=[

	Tally: A total spread over a fixed set of keys.

	Each server writes its own shard and never waits behind another. A total only goes up, and no
	single key knows it. Mine picks this server's shard and Shards names them all. The running total
	lives in a field of Ledger's own rather than the game's.

	Cache names the item a summed total lives in, which a store keeps fresh the way it keeps a copy
	of any key. The state in that item carries the sum and the second each shard was read, so a
	server lays over the sum only the bumps it made after its own shard was read. Since reads that
	second back out.

	Return type: A table with Layered, Bump, Counted, Mine, Shard, Keys, Cache and Since. The type is Bucket.
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
local Layer = require("./Layer")
local Shapes = require("../Core/Shapes")

type Op = Shapes.Op
type Data = Shapes.Folded

export type Bucket = {
	Seq: number,
	At: number,
	Amount: number,
}

local LastNode = ""
local LastCount = 0
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

local function Mine(Node: string?, Count: number?): number
	local Home = Node or Ids.Home()
	local Over = Count or Shards.SHARDS
	if Home ~= LastNode or Over ~= LastCount then
		LastNode = Home
		LastCount = Over
		LastShard = Digest.Bucket(Home, Over)
	end
	return LastShard
end

local function Shard(Name: string, Index: number): string
	return `{Name}{Shards.PART}{Index}`
end

local function Keys(Name: string, Count: number?): { string }
	local Over = Count or Shards.SHARDS
	local Keys: { string } = table.create(Over) :: { string }
	for Index = 1, Over do
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

local function Since(State: any, Shard: number): number?
	if type(State) ~= "table" then
		return nil
	end

	local Read: any = State.Read
	if type(Read) ~= "table" then
		return nil
	end

	local At = Read[Shard + 1]
	return if type(At) == "number" then At else nil
end

local Held: Layer.Layer = {
	Kinds = {
		[Kinds.BUMP] = Bumping,
	},
	Owns = {
		{ Field = Shards.FIELD, Says = "the tally" },
	},
}

local function Layered(_Balance: string?): Layer.Layer
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
	Since = Since,
})
