--!strict
--!optimize 2

--[=[

	Tally: A total spread over a fixed set of keys.

	Each server writes its own shard and never waits behind another. A total only goes up, and no
	single key knows it. Mine picks this server's shard, Shard names one and Keys names them all. The
	running total lives in a field of Ledger's own rather than the game's.

	Cache names the item a summed total lives in, which a store keeps fresh the way it keeps a copy
	of any key. The state in that item carries the sum, the second each shard was read and the count
	each shard had reached, so a server lays over the sum only the bumps it made after its own shard
	was read. A shard's count only goes up, so a bump whose write left the shard at a count the read
	did not reach came after it, whatever the clocks of the two servers say. The second is for items
	an older server wrote without counts. Item builds that state, and Sum, Since and Reached read it
	back, so its shape lives in this file alone. A tally over a count
	of shards other than the default names that count in its item, so two builds with different
	counts never read each other's sum.

	Return type: A table with Layered, Bump, Counted, Mine, Shard, Keys, Cache, Item, Sum, Since and Reached. The types are Bucket and Summed.
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
	Count: number?,
}

export type Summed = {
	Sum: number,
	Read: { number },
	Counts: { number },
}

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
	return Digest.Bucket(Node or Ids.Home(), Count or Shards.SHARDS)
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

local function Cache(Store: string, Name: string, Field: string, Count: number?): string
	local Over = Count or Shards.SHARDS
	if Over == Shards.SHARDS then
		return Mark.Cached({ Store, Name, Field })
	end
	return Mark.Cached({ Store, Name, Field, tostring(Over) })
end

local function Item(Sum: number, Read: { number }, Counts: { number }): Summed
	return { Sum = Sum, Read = Read, Counts = Counts }
end

local function Sum(State: any): number?
	if type(State) ~= "table" or type(State.Sum) ~= "number" then
		return nil
	end
	return State.Sum
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

local function Reached(State: any, Shard: number): number?
	if type(State) ~= "table" then
		return nil
	end

	local Counts: any = State.Counts
	if type(Counts) ~= "table" then
		return nil
	end

	local Count = Counts[Shard + 1]
	return if type(Count) == "number" and Count == Count then Count else nil
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
	Item = Item,
	Sum = Sum,
	Since = Since,
	Reached = Reached,
})
