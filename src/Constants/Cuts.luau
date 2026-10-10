--!strict
--!optimize 2

--[=[
	Cuts: the constants of Erase and Reset. The rooms a cut writes into, and GateMax, are in Record because
	BookMax needs them and Cuts needs Record.

	Return type: A frozen table of the constants.
	Example usage:
		local Cuts = require("./Constants/Cuts")
		local Age = Cuts.SealAge
--]=]

local Record = require("./Record")

local FoldSpansPerCeiling = 2
local FoldSpan = Record.Ceiling / FoldSpansPerCeiling
local SlotSpans = 2
local FoldSlotsMost = 2

local KeepNamedDays = 7
local KeepNamed = KeepNamedDays * Record.SecondsPerDay

local ResetMax = Record.BytesPerMiB

local RemoveLate = Record.SecondsPerHour
local RemoveSend = Record.SecondsPerMinute

local SealAge = RemoveSend + RemoveLate + Record.SkewSigmas * Record.Sigma

local FencesPerSecond = 8
local FenceAndSkew = Record.MarkCap / FencesPerSecond + Record.SkewSigmas * Record.Sigma

local EraseDelayCount = 9
local EraseBound = EraseDelayCount * Record.Delay + FenceAndSkew

local ResetDelayCount = 7
local ResetBound = ResetDelayCount * Record.Delay + FenceAndSkew

local CutOpKind = "Cut"

return table.freeze({
	FoldSpan = FoldSpan,
	SlotSpans = SlotSpans,
	FoldSlotsMost = FoldSlotsMost,
	KeepNamed = KeepNamed,
	ResetMax = ResetMax,
	RemoveLate = RemoveLate,
	RemoveSend = RemoveSend,
	SealAge = SealAge,
	FencesPerSecond = FencesPerSecond,
	EraseDelayCount = EraseDelayCount,
	EraseBound = EraseBound,
	ResetDelayCount = ResetDelayCount,
	ResetBound = ResetBound,
	CutOpKind = CutOpKind,
})
