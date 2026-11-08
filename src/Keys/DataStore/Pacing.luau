--!strict
--!optimize 2

--[=[
	Pacing: a shard's or part's send gap and read interval (extras sheet E3, E10). A new shard writer first waits a
	random fraction of GapMost; a part's writer sends at once from GapLeast, since a take waits on its answer. A
	landing scales the gap by the write rate over the target rate, at least by half. An interval doubles after a
	round with a throttled read, else halves after one with a good read.

	Return type: A plain table of functions and the RoundOutcomes, and the Paced, Landing and RoundOutcome types.
	Example usage:
		local Paced = Pacing.NewPaced(true, Clock, Fraction, Limits)
		if Pacing.MaySend(Paced, Clock) then Pacing.NoteSend(Paced, Clock) end
--]=]

local Extras = require("../Constants/Extras")
local Record = require("../Constants/Record")

type GapLimits = { read GapLeast: number, read GapMost: number }

export type Landing = {
	read Writes: number,
	read Clock: number,
}

export type Paced = {
	Gap: number,
	LastSend: number?,
	read FirstSendAt: number,
	Previous: Landing?,
	Last: Landing?,
	read IsShard: boolean,
}

local GapFactorLeast = 1 / 2
local IntervalFactor = 2

local RoundOutcomes = {
	Throttled = "Throttled" :: "Throttled",
	Good = "Good" :: "Good",
	Failed = "Failed" :: "Failed",
}
export type RoundOutcome = keyof<typeof(RoundOutcomes)>

local function NewPaced(IsShard: boolean, Clock: number, Fraction: number, Limits: GapLimits): Paced
	if not IsShard then
		return {
			Gap = Limits.GapLeast,
			LastSend = nil,
			FirstSendAt = Clock,
			Previous = nil,
			Last = nil,
			IsShard = IsShard,
		}
	end
	return {
		Gap = Limits.GapMost,
		LastSend = nil,
		FirstSendAt = Clock + Fraction * Limits.GapMost,
		Previous = nil,
		Last = nil,
		IsShard = IsShard,
	}
end

local function NextSendAt(Paced: Paced): number
	if Paced.LastSend == nil then
		return Paced.FirstSendAt
	end
	return Paced.LastSend + Paced.Gap
end

local function MaySend(Paced: Paced, Clock: number): boolean
	return Clock >= NextSendAt(Paced)
end

local function NoteSend(Paced: Paced, Clock: number)
	Paced.LastSend = Clock
end

local function TargetRate(Bytes: number, IsShard: boolean): number
	local Kibibytes = math.max(1, math.ceil(Bytes / Record.BytesPerKiB))
	local Rate = math.floor(Extras.WriteCeilingKiB / Kibibytes)
	if IsShard then
		return Rate / Extras.ShardRateShare
	end
	return Rate
end

local function NoteLanding(Paced: Paced, Writes: number, Clock: number, Bytes: number, Limits: GapLimits)
	Paced.Previous = Paced.Last
	Paced.Last = { Writes = Writes, Clock = Clock }
	local Previous = Paced.Previous
	if Previous == nil then
		return
	end
	local Span = Clock - Previous.Clock
	if Span < Extras.RateSpanLeast then
		return
	end
	local Rate = (Writes - Previous.Writes) * Record.SecondsPerMinute / Span
	local Factor = math.max(Rate / TargetRate(Bytes, Paced.IsShard), GapFactorLeast)
	Paced.Gap = math.clamp(Paced.Gap * Factor, Limits.GapLeast, Limits.GapMost)
end

local function Interval(Outcome: RoundOutcome, Current: number): number
	if Outcome == RoundOutcomes.Throttled then
		return math.min(Current * IntervalFactor, Extras.IntervalMost)
	end
	if Outcome == RoundOutcomes.Good then
		return math.max(Current / IntervalFactor, Extras.IntervalFirst)
	end
	return Current
end

return {
	NewPaced = NewPaced,
	NextSendAt = NextSendAt,
	MaySend = MaySend,
	NoteSend = NoteSend,
	TargetRate = TargetRate,
	NoteLanding = NoteLanding,
	Interval = Interval,
	RoundOutcomes = RoundOutcomes,
}
