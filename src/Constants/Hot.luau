--!strict
--!optimize 2

--[=[
	Hot: the numbers, modes, op kinds and part flag bit of split quantities. Seconds unless a name says bytes or a
	count. The values are the hot keys sheet's H1, H2, H5 and H11. A part's record is kept in a state table under
	PartRecordKey, which is never storable, so no field a game declares can be it.

	Return type: A frozen table of the constants, PartOpKinds a list of the part op kinds, and the Mode and PartOpKind
	types.
	Example usage:
		local Hot = require("./Constants/Hot")
		local Kind = Hot.PartOpKind.Take
--]=]

local Extras = require("./Extras")
local Record = require("./Record")

local HoldSlackSigmas = 2

local PartsLeast = 1
local PartsMost = Extras.ShardsMost
local ProbeMax = 3
local ProceedsMax = 4

local HoldRoom = 256
local HoldItemMax = 40
local HoldSlack = HoldSlackSigmas * Record.Sigma

local ViewAge = 30

local PartSealedBit = 1
local PartClosedBit = 2
local PartSerialBit = 4
local PartFinalBit = 8
local PartFlagsMost = PartSealedBit + PartClosedBit + PartSerialBit + PartFinalBit

local Mode = {
	Final = "Final" :: "Final",
	Open = "Open" :: "Open",
}

export type Mode = keyof<typeof(Mode)>

local PartOpKind = {
	Open = "Open" :: "Open",
	Take = "Take" :: "Take",
	Credit = "Credit" :: "Credit",
	Close = "Close" :: "Close",
	Hold = "Hold" :: "Hold",
	Confirm = "Confirm" :: "Confirm",
	Release = "Release" :: "Release",
}

export type PartOpKind = keyof<typeof(PartOpKind)>

local PartOpKinds: { PartOpKind } = {
	PartOpKind.Open,
	PartOpKind.Take,
	PartOpKind.Credit,
	PartOpKind.Close,
	PartOpKind.Hold,
	PartOpKind.Confirm,
	PartOpKind.Release,
}

local PartRecordKey = ""
local FreeField = "u"
local DebitKindPrefix = "Debit:"

return table.freeze({
	PartsLeast = PartsLeast,
	PartsMost = PartsMost,
	ProbeMax = ProbeMax,
	ProceedsMax = ProceedsMax,
	HoldRoom = HoldRoom,
	HoldItemMax = HoldItemMax,
	HoldSlack = HoldSlack,
	ViewAge = ViewAge,
	PartSealedBit = PartSealedBit,
	PartClosedBit = PartClosedBit,
	PartSerialBit = PartSerialBit,
	PartFinalBit = PartFinalBit,
	PartFlagsMost = PartFlagsMost,
	Mode = table.freeze(Mode),
	PartOpKind = table.freeze(PartOpKind),
	PartOpKinds = table.freeze(PartOpKinds),
	PartRecordKey = PartRecordKey,
	FreeField = FreeField,
	DebitKindPrefix = DebitKindPrefix,
})
