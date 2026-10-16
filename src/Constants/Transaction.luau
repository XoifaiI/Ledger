--!strict
--!optimize 2

--[=[
	Transaction: the numbers of the transaction design that are not the record's (the transaction sheet's
	section 2). Seconds unless a name says bytes or a count. PinEvictAge is the record's, and the default of
	OrphanAge is Settable's.

	Return type: A frozen table of the constants, with ProveName, ProveStamp and ProveSealer, the drawn name,
	stamp and sealer of a ProveGone's seal.
	Example usage:
		local Transaction = require("./Constants/Transaction")
		local Age = Transaction.SettleAge
--]=]

local Record = require("./Record")

local SettleAge = 10
local MaxAttempts = 3
local RetryRounds = 3

local OwedRecordsVerified = 8
local OpMax = Record.PostCap
local GameOpMarksMost = 3
local LegLeast = 2

local OrphanAgeSigmasBelowCeiling = 2
local WindowSigmasBelowOrphanAge = 2
local OrphanAgeLeast = Record.SecondsPerHour
local OrphanAgeMost = Record.Ceiling - OrphanAgeSigmasBelowCeiling * Record.Sigma

local TouchStepSigmas = 2
local TouchStepDelays = 3
local TouchBoundSigmas = 2
local TouchBoundDelays = 4

local TouchLevels = 16
local ReadLag = 4
local TouchStep = ReadLag + TouchStepSigmas * Record.Sigma + TouchStepDelays * Record.Delay
local TouchBound = SettleAge
	+ TouchLevels * TouchStep
	+ ReadLag
	+ TouchBoundSigmas * Record.Sigma
	+ TouchBoundDelays * Record.Delay

local HoldDrop = 30
local FoldWindow = 30

local ProveName = table.freeze({ Kind = "Drawn" :: "Drawn", Server = 0, Counter = 0 })
local ProveStamp = 0
local ProveSealer = 0

return table.freeze({
	SettleAge = SettleAge,
	MaxAttempts = MaxAttempts,
	RetryRounds = RetryRounds,
	OwedRecordsVerified = OwedRecordsVerified,
	OpMax = OpMax,
	GameOpMarksMost = GameOpMarksMost,
	LegLeast = LegLeast,
	OrphanAgeLeast = OrphanAgeLeast,
	OrphanAgeMost = OrphanAgeMost,
	WindowSigmasBelowOrphanAge = WindowSigmasBelowOrphanAge,
	TouchLevels = TouchLevels,
	ReadLag = ReadLag,
	TouchStep = TouchStep,
	TouchBound = TouchBound,
	HoldDrop = HoldDrop,
	FoldWindow = FoldWindow,
	ProveName = ProveName,
	ProveStamp = ProveStamp,
	ProveSealer = ProveSealer,
})
