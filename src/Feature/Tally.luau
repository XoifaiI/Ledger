--!strict
--!optimize 2

--[=[
	Tally: A total that is spread over a fixed set of keys.

	Each server writes its own key, and does not wait behind the others.
	A tally can only go up. No key can see the others, so no key knows the total,
	and a limit cannot hold across them.
	The total lives in a field of Ledger's own. The game's field on a shard is left at nothing once a
	bump has moved the total across, so a build that still writes the old way adds to a field that is
	counted alongside the total rather than hidden behind it.

	Return type: A table with Layered, Bump, Counted, Mine, Shard, Shards, SHARDS, PART, FIELD and CARRIED.
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
local CARRIED = "_Carried"

local LastNode = ""
local LastShard = 0

local function Counted(State: any, Field: string, Base: number): (number, boolean)
	if type(State) ~= "table" then
		return 0, false
	end

	local Sums = State[FIELD]
	local Value = State[Field]
	if type(Sums) == "table" and type(Sums[Field]) == "number" then
		local Carried = Sums[CARRIED]
		local Held = Sums[Field] + (if type(Value) == "number" then Value else 0)
		return math.max(Held, 0), type(Carried) == "table" and Carried[Field] ~= nil
	end

	if type(Value) ~= "number" then
		return 0, false
	end
	return math.max(Value - Base, 0), Value ~= Base
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

	local Raw = Data[Field]
	local Guessed = type(Moved) ~= "number" and Raw ~= Base
	local Sum = if type(Moved) == "number" then Moved + Raw else math.max(Raw - (Base :: number), 0)

	local Kept: Data = if type(Sums) == "table" then table.clone(Sums :: Data) else {}
	Kept[Field] = Sum + Op.Amount
	if Guessed then
		local Held = Kept[CARRIED]
		local Marked: Data = if type(Held) == "table" then table.clone(Held :: Data) else {}
		Marked[Field] = { Absorbed = Raw, Assumed = Base }
		Kept[CARRIED] = Marked
	end

	local Next = table.clone(Data)
	Next[Field] = 0
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
	CARRIED = CARRIED,
})
