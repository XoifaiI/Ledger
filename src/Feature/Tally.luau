--!strict
--!optimize 2

--[=[
	Tally: A total that is spread over a fixed set of keys.

	Each server writes its own key, and does not wait behind the others.
	A tally can only go up. No key can see the others, so no key knows the total,
	and a limit cannot hold across them.
	The total lives in a field of Ledger's own, and the game's own field on a shard is never touched.
	A shard therefore says what it holds on its own, without the Default it was built from having to
	be known.

	Return type: A table with Layered, Bump, Counted, Mine, Shard, Shards, SHARDS, PART and FIELD.
	Example usage:
		local Tally = require("./Tally")
		local Key = Tally.Shard(Name, Tally.Mine())
--]=]

local Fingerprint = require("../Encode/Fingerprint")
local Ident = require("../Encode/Ident")
local Arg = require("../Kernel/Arg")
local Layer = require("../Kernel/Layer")
local Op = require("../Contract/Op")

type Op = Op.Op
type Data = { [any]: any }

local BUMP = "__Bump"
local SHARDS = 16
local PART = "#"
local FIELD = "_Tally"

local LastNode = ""
local LastShard = 0

local function Counted(State: any, Field: string): number
	if type(State) ~= "table" then
		return 0
	end

	local Sums = State[FIELD]
	if type(Sums) ~= "table" or type(Sums[Field]) ~= "number" then
		return 0
	end
	return math.max(Sums[Field], 0)
end

local function Bumping(Data: Data, Op: Op): Data?
	local Field = Op.Field
	if type(Field) ~= "string" or type(Data[Field]) ~= "number" then
		return nil
	end
	if not Arg.Positive(Op.Amount) then
		return nil
	end

	local Sums = Data[FIELD]
	local Held = if type(Sums) == "table" then Sums :: Data else nil
	local Running = if Held ~= nil and type(Held[Field]) == "number" then Held[Field] else 0

	local Kept: Data = if Held ~= nil then table.clone(Held) else {}
	Kept[Field] = Running + Op.Amount

	local Next = table.clone(Data)
	Next[FIELD] = Kept
	return Next
end

local function Mine(): number
	local Node = Ident.Home()
	if Node ~= LastNode then
		LastNode = Node
		LastShard = Fingerprint.Bucket(Node, SHARDS)
	end
	return LastShard
end

local function Shard(Name: string, Index: number): string
	return `{Name}{PART}{Index}`
end

local function Shards(Name: string): { string }
	local Keys: { string } = table.create(SHARDS) :: { string }
	for Index = 1, SHARDS do
		Keys[Index] = Shard(Name, Index - 1)
	end
	return Keys
end

local function Bump(Field: string, Amount: number): Op
	return { Id = Ident.Fresh(), Kind = BUMP, Field = Field, Amount = Amount } :: any
end

local Held: Layer.Layer = {
	Kinds = {
		[BUMP] = Bumping,
	},
	Owns = {
		{ Field = FIELD, Says = "the tally" },
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
	Shards = Shards,
	SHARDS = SHARDS,
	PART = PART,
	FIELD = FIELD,
})
