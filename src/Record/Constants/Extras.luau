--!strict
--!optimize 2

--[=[
	Extras: the numbers of totals, the summary item and copies that have a meaning. Seconds unless a name says
	bytes, kilobytes or a count. The values are the extras sheet's E1, E3, E5 to E10.

	Return type: A frozen table of the constants.
	Example usage:
		local Extras = require("./Constants/Extras")
		local Shards = Extras.ShardsDefault
--]=]

local Record = require("./Record")

local ShardsDefault = 16
local ShardsMost = 64
local ShardSumMost = Record.VarintLimit - 1
local ShardSumField = "s"
local BumpOpKind = "Bump"

local GapLeast = 1
local GapMost = 60
local WriteCeilingKiB = 4096
local ShardRateShare = 2
local RateSpanLeast = 1

local PruneAge = Record.SecondsPerDay

local RefreshEvery = 15
local CheckEvery = 30
local HolderSpan = RefreshEvery + Record.Delay + Record.SkewSigmas * Record.Sigma
local TakerJitter = 30
local LapseSlack = Record.SkewSigmas * Record.Sigma + Record.Delay

local IntervalFirst = 60
local IntervalMost = 960

local SummaryExpiry = Record.SecondsPerHour
local CopyExpiry = Record.SecondsPerHour
local CopyPushAge = CopyExpiry / 2
local ItemRoom = 32000
local CopySlots = 2

local TickFirst = 30
local TickMost = 240
local TickFactor = 2
local PartMissesForTaker = 2

local BreakerMisses = 3
local BreakerOpenMinutes = 2
local BreakerOpenFor = BreakerOpenMinutes * Record.SecondsPerMinute

return table.freeze({
	ShardsDefault = ShardsDefault,
	ShardsMost = ShardsMost,
	ShardSumMost = ShardSumMost,
	ShardSumField = ShardSumField,
	BumpOpKind = BumpOpKind,
	GapLeast = GapLeast,
	GapMost = GapMost,
	WriteCeilingKiB = WriteCeilingKiB,
	ShardRateShare = ShardRateShare,
	RateSpanLeast = RateSpanLeast,
	PruneAge = PruneAge,
	RefreshEvery = RefreshEvery,
	CheckEvery = CheckEvery,
	HolderSpan = HolderSpan,
	TakerJitter = TakerJitter,
	LapseSlack = LapseSlack,
	IntervalFirst = IntervalFirst,
	IntervalMost = IntervalMost,
	SummaryExpiry = SummaryExpiry,
	CopyExpiry = CopyExpiry,
	CopyPushAge = CopyPushAge,
	ItemRoom = ItemRoom,
	CopySlots = CopySlots,
	TickFirst = TickFirst,
	TickMost = TickMost,
	TickFactor = TickFactor,
	PartMissesForTaker = PartMissesForTaker,
	BreakerMisses = BreakerMisses,
	BreakerOpenFor = BreakerOpenFor,
})
