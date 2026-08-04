--!strict
--!optimize 2

--[=[
	Tally: A total that is spread over a fixed set of keys.
	
	Each server writes its own key, and does not wait behind the others.
	A tally can only go up. No key can see the others, so no key knows the total,
	and a limit cannot hold across them.
	
	Return type: A table with Layered, Bump, Mine, Shard, Shards, SHARDS and PART.
	Example usage:
		local Tally = require("./Tally")
		local Key = Tally.Shard(Name, Tally.Mine())
--]=]

local EncodingService = game:GetService("EncodingService")

local Ident = require("../Encode/Ident")
local Layer = require("../Kernel/Layer")
local Op = require("../Contract/Op")

type Op = Op.Op
type Data = { [any]: any }

local BUMP = "__Bump"
local SHARDS = 16
local PART = "#"
local ALGORITHM = Enum.HashAlgorithm.Blake3

local function Bumping(Data: Data, Op: Op): Data?
	local Field = Op.Field
	if type(Field) ~= "string" or type(Data[Field]) ~= "number" then
		return nil
	end
	if type(Op.Amount) ~= "number" or Op.Amount <= 0 or Op.Amount == math.huge then
		return nil
	end

	local Next = table.clone(Data)
	Next[Field] += Op.Amount
	return Next
end

local Home = ""
local Picked = 0

local function Mine(): number
	local Node = Ident.Home()
	if Node ~= Home then
		Home = Node
		Picked = string.byte(EncodingService:ComputeStringHash(Node, ALGORITHM), 1) % SHARDS
	end
	return Picked
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
		[BUMP] = Bumping
	}
}

local function Layered(_Balance: string?): Layer.Layer?
	return Held
end

return table.freeze({
	Layered = Layered,

	Bump = Bump,
	Mine = Mine,
	Shard = Shard,
	Shards = Shards,
	SHARDS = SHARDS,
	PART = PART
})
