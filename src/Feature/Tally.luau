--!strict
--!optimize 2

--[=[
	Tally: A total that is spread over a fixed set of keys.

	Each server writes its own key, and does not wait behind the others.
	A tally can only go up. No key can see the others, so no key knows the total,
	and a limit cannot hold across them.

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

-- Gives back what one shard adds, and whether it was read the way a build before this one wrote it.
-- A key nobody has bumped holds the Default and nothing else, so it reads as nothing and counts as
-- neither.
local function Counted(State: any, Field: string, Base: number): (number, boolean)
	if type(State) ~= "table" then
		return 0, false
	end

	local Sums = State[FIELD]
	if type(Sums) == "table" and type(Sums[Field]) == "number" then
		return Sums[Field], false
	end

	local Value = State[Field]
	if type(Value) ~= "number" then
		return 0, false
	end
	return Value - Base, Value ~= Base
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
	local Moved = if type(Sums) == "table" then Sums[Field] else nil
	local Base = Op.Base

	if type(Moved) ~= "number" and type(Base) ~= "number" then
		local Stale = table.clone(Data)
		Stale[Field] += Op.Amount
		return Stale
	end

	local Sum = if type(Moved) == "number" then Moved else Data[Field] - (Base :: number)

	local Kept: Data = if type(Sums) == "table" then table.clone(Sums :: Data) else {}
	Kept[Field] = Sum + Op.Amount

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

local function Bump(Field: string, Amount: number, Base: number): Op
	return { Id = Ident.Fresh(), Kind = BUMP, Field = Field, Amount = Amount, Base = Base } :: any
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
