--!strict
--!optimize 2

-- an add only total spread over a fixed set of keys, so every server writes its own shard instead of queueing behind the others. it can only be added to, because no shard knows the total and a limit cannot be held across them

local EncodingService = game:GetService("EncodingService")

local Ident = require("./Ident")
local Types = require("../Types")

type Op = Types.Op
type Reducer<S> = Types.Reducer<S>

local BUMP = "__Bump"
local SHARDS = 16
local PART = "#"
local ALGORITHM = Enum.HashAlgorithm.Blake3

local function Bumping(Data: { [any]: any }, Op: Op): { [any]: any }?
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

local function Wrap<S>(GameReducer: Reducer<S>): Reducer<S>
	local function Combined(State: S, Op: Op): S?
		if Op.Kind == BUMP then
			return Bumping(State :: any, Op) :: any
		end
		return GameReducer(State, Op)
	end

	return Combined
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

return table.freeze({
	Wrap = Wrap,
	Bump = Bump,
	Mine = Mine,
	Shard = Shard,
	Shards = Shards,
	SHARDS = SHARDS,
	PART = PART
})
