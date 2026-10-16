--!strict
--!optimize 2

--[=[
	Shard: a total's shard (extras sheet E1, E2 B0, B5, B6): its key, build and bump terms. The state is
	{ s = sum }, created at 0; the reducer is the bump rule, and a bump past ShardMax gives no state, so the op is
	Refused. BumpTerms refuses what a call must not send.

	Return type: A plain table of functions, and the BumpTerms type.
	Example usage:
		local Key = Shard.ShardKey("Shop", "global", { Name = "coins", KeyCount = 16, Keys = "Shard" }, 3)
		--> { Store = "Shop", Scope = "global", Key = "$T:coins:16:3" }
--]=]

local Extras = require("../../Constants/Extras")
local ExtrasShapes = require("../Shapes")
local Names = require("../../Encoding/Names")
local Record = require("../../Constants/Record")
local Shapes = require("../../Shapes")

type Build = Shapes.Build
type StoreKey = Names.StoreKey
type TotalDeclaration = ExtrasShapes.TotalDeclaration
type Fields = { [unknown]: unknown }

export type BumpTerms = {
	read Amount: number,
	read Shards: number,
}

type ShardRef = {
	read Total: TotalDeclaration,
	read Index: number,
}

local KeyKinds = Record.KeyKind

local ShardSumField = Extras.ShardSumField
local ShardSumMost = Extras.ShardSumMost
local ShardsMost = Extras.ShardsMost

local ShardKeyPrefix = Record.ShardKeyPrefix
local ShardKeyShape = "^(.*):(%d+):(%d+)$"

local ModuleName = "Shard"
local CallerMustGive = `{ModuleName}: a bump holds a number under {ShardSumField} in its state, and an Amount and`
	.. ` Shards in its terms. The caller must give them`
local ShardsOutOfRange = `{ModuleName}: a total has a whole number of shards from 1 to {ShardsMost}. The caller must`
	.. ` give one`
local AmountOutOfRange = `{ModuleName}: a bump's Amount is a whole number of at least 1 in size and at most ShardMax.`
	.. ` The caller must give one`
local NotAShardKey = `{ModuleName}: this key does not name a shard of a total. The caller must give a shard's key`

local function ShardMax(Shards: number): number
	return math.floor(ShardSumMost / Shards)
end

local function SumOfState(State: unknown): number
	if type(State) ~= "table" then
		error(CallerMustGive)
	end
	local Sum = (State :: Fields)[ShardSumField]
	if type(Sum) ~= "number" then
		error(CallerMustGive)
	end
	return Sum
end

local function ShardKey(Store: string, Scope: string, Total: TotalDeclaration, Index: number): StoreKey
	return { Store = Store, Scope = Scope, Key = `{ShardKeyPrefix}{Total.Name}:{Total.KeyCount}:{Index}` }
end

local function ShardOfKey(Key: StoreKey): ShardRef
	local Name, Shards, Index = string.match(string.sub(Key.Key, #ShardKeyPrefix + 1), ShardKeyShape)
	local ShardCount = tonumber(Shards)
	local ShardIndex = tonumber(Index)
	if Name == nil or ShardCount == nil or ShardIndex == nil then
		error(NotAShardKey)
	end
	return { Total = { Name = Name, KeyCount = ShardCount, Keys = KeyKinds.Shard }, Index = ShardIndex }
end

local function BumpTerms(Amount: number, Shards: number): BumpTerms
	if Shards % 1 ~= 0 or Shards < 1 or Shards > ShardsMost then
		error(ShardsOutOfRange)
	end
	local Size = math.abs(Amount)
	if Amount % 1 ~= 0 or Size < 1 or Size > ShardMax(Shards) then
		error(AmountOutOfRange)
	end
	return { Amount = Amount, Shards = Shards }
end

local function BumpTermsOf(Terms: unknown): BumpTerms
	if type(Terms) ~= "table" then
		error(CallerMustGive)
	end
	local Given = Terms :: Fields
	local Amount = Given.Amount
	local Shards = Given.Shards
	if type(Amount) ~= "number" or type(Shards) ~= "number" then
		error(CallerMustGive)
	end
	return { Amount = Amount, Shards = Shards }
end

local function Bump(State: unknown, Terms: unknown): Fields?
	local Given = BumpTermsOf(Terms)
	local Sum = SumOfState(State) + Given.Amount
	if math.abs(Sum) > ShardMax(Given.Shards) then
		return nil
	end
	return { [ShardSumField] = Sum }
end

local function NewBuild(): Build
	local Made: Build = {
		KeyKind = KeyKinds.Shard,
		Migrations = {},
		MigrationCount = 0,
		BreakingIndex = 0,
		Reducer = Bump,
		Default = { [ShardSumField] = 0 },
		Declared = { [ShardSumField] = true },
		Balances = {},
		BalanceOps = {},
	}
	table.freeze(Made.Migrations)
	table.freeze(Made.Default)
	table.freeze(Made.Declared)
	table.freeze(Made.Balances)
	table.freeze(Made.BalanceOps)
	return table.freeze(Made)
end

return {
	ShardKey = ShardKey,
	ShardOfKey = ShardOfKey,
	ShardMax = ShardMax,
	SumOfState = SumOfState,
	BumpTerms = BumpTerms,
	NewBuild = NewBuild,
}
