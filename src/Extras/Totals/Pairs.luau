--!strict
--!optimize 2

--[=[
	Pairs: a total's local pairs and its summary item's breaker (extras sheet E4). A pair or landing merges by
	the larger q, the held one on a tie. BreakerMisses misses in a row open the breaker for BreakerOpenFor
	seconds; the next miss after that reopens it; a hit shuts it.

	Return type: A plain table of functions.
	Example usage:
		Pairs.MergePair(View, 0, { Q = 3, Sum = 40 })
		if Pairs.IsComplete(View, Shards) then Total = Pairs.SumOf(View, Shards) end
--]=]

local Extras = require("../../Constants/Extras")
local ExtrasShapes = require("../Shapes")
local ExtrasState = require("../State")
local Shapes = require("../../Shapes")
local Shard = require("./Shard")
local Value = require("../../Stored/Value")

type Pair = ExtrasShapes.Pair
type TotalView = ExtrasState.TotalView
type LandedValue = Shapes.LandedValue
type Kept = Value.Kept

local BreakerMisses = Extras.BreakerMisses
local BreakerOpenFor = Extras.BreakerOpenFor

local SumNeedsEveryPair =
	"Pairs: this call is never made. SumOf is given only a complete view; the caller checks IsComplete first."

local function Merged(Held: Pair?, Offered: Pair): Pair
	if Held ~= nil and Offered.Q <= Held.Q then
		return Held
	end
	return Offered
end

local function MergePair(View: TotalView, Index: number, Pair: Pair)
	View.Pairs[Index] = Merged(View.Pairs[Index], Pair)
end

local function PairOf(Stored: Kept): Pair
	return { Q = Stored.Book.Writes, Sum = Shard.SumOfState(Stored.State) }
end

local function MergeLanded(View: TotalView, Index: number, Landed: LandedValue)
	MergePair(View, Index, PairOf(Landed.Written))
end

local function Pairless(View: TotalView, Shards: number): { number }
	local Missing: { number } = {}
	for Index = 0, Shards - 1 do
		if View.Pairs[Index] == nil then
			table.insert(Missing, Index)
		end
	end
	return Missing
end

local function IsComplete(View: TotalView, Shards: number): boolean
	return #Pairless(View, Shards) == 0
end

local function SumOf(View: TotalView, Shards: number): number
	local Sum = 0
	for Index = 0, Shards - 1 do
		local Held = View.Pairs[Index]
		if Held == nil then
			error(SumNeedsEveryPair)
		end
		Sum += Held.Sum
	end
	return Sum
end

local function IsFresh(View: TotalView, Clock: number, MaxAge: number): boolean
	local SeenAt = View.SeenAt
	if SeenAt == nil then
		return false
	end
	return Clock - SeenAt <= MaxAge
end

local function ReadWithin(View: TotalView, Index: number, Clock: number): boolean
	local ReadAt = View.ReadAt[Index]
	if ReadAt == nil then
		return false
	end
	return Clock - ReadAt <= View.Interval
end

local function HasReadEveryKey(View: TotalView, KeyCount: number, Clock: number): boolean
	for Index = 0, KeyCount - 1 do
		if not ReadWithin(View, Index, Clock) then
			return false
		end
	end
	return true
end

local function NoteMiss(View: TotalView, Clock: number)
	local Breaker = View.Breaker
	Breaker.Misses += 1
	if Breaker.Misses >= BreakerMisses then
		Breaker.OpenUntil = Clock + BreakerOpenFor
	end
end

local function NoteHit(View: TotalView)
	View.Breaker.Misses = 0
	View.Breaker.OpenUntil = nil
end

local function IsOpen(View: TotalView, Clock: number): boolean
	local OpenUntil = View.Breaker.OpenUntil
	if OpenUntil == nil then
		return false
	end
	return Clock < OpenUntil
end

return {
	MergePair = MergePair,
	MergeLanded = MergeLanded,
	PairOf = PairOf,
	Pairless = Pairless,
	IsComplete = IsComplete,
	SumOf = SumOf,
	IsFresh = IsFresh,
	ReadWithin = ReadWithin,
	HasReadEveryKey = HasReadEveryKey,
	NoteMiss = NoteMiss,
	NoteHit = NoteHit,
	IsOpen = IsOpen,
}
