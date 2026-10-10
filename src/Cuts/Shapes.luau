--!strict
--!optimize 2

--[=[
	Shapes: the shapes a cut puts in an op, a request, a report, a call and its answer (cuts sheets 1.3, 4, 5.3,
	8 and 9).

	A CutForm is the op form of a cut. The call types are the cut's own. A cut call's answer of true is a CutAnswer.

	Return type: An empty table. The types are Role, CutForm, SealStampRequest, CutReport, EraseCall,
	ResetCall, SeenSeal and CutAnswer.
	Example usage:
		local CutShapes = require("./Cuts/Shapes")
		type CutForm = CutShapes.CutForm
--]=]

local Losses = require("../Stored/Items/Losses")
local Names = require("../Encoding/Names")
local Timed = require("../Stored/Items/Timed")
local Value = require("../Stored/Value")

type GivenName = Names.GivenName
type OpName = Names.OpName
type LossRecords = Losses.LossRecords
type StoreKey = Names.StoreKey
type Fields = Value.Fields
type CutKind = Timed.CutKind

export type Role = "Cutter" | "Helper"

export type CutForm = {
	read Kind: "Cut",
	read Name: OpName,
	read CutKind: CutKind,
	read Role: Role,
	read Given: Fields?,
	read Sender: number,
}

export type SealStampRequest = {
	read Kind: "SealStamp",
	read RemovalStamp: number,
	read Server: number,
}

export type CutReport =
	{ read Kind: "Took" }
	| { read Kind: "Full" }
	| { read Kind: "Stamped", read RemovalStamp: number, read Sealer: number }

export type EraseCall = {
	read Kind: "Call",
	read Method: "Erase",
	read CallId: number,
	read Key: StoreKey,
	read Name: GivenName?,
}

export type ResetCall = {
	read Kind: "Call",
	read Method: "Reset",
	read CallId: number,
	read Key: StoreKey,
	read Name: GivenName?,
	read Given: Fields?,
}

export type SeenSeal = {
	read Key: StoreKey,
	read RemovalStamp: number,
}

export type CutAnswer = {
	read Name: GivenName,
	read Namings: LossRecords?,
}

return {}
