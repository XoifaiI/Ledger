--!strict
--!optimize 2

--[=[
	Shapes: the shapes a transaction puts in a request, an end, a note and a report (transaction sheet 4).

	A Tent or a Commit is an op form that carries its leg. Each End, a Resolve, a Drop or a Fence, has one report in
	Note.EndReports. A Refused report carries the state its transform read, none from a stored fate.

	Return type: An empty table. The types are TxLeg, DeltaLeg, GameLeg, LegForm, TentForm, CommitForm, TxOutcome,
	DroppedName, ResolveEnd, DropEnd, FenceEnd, End, TxReport, Carrier, HeldEnd and AbortedUse.
	Example usage:
		local TxShapes = require("./Tx/Shapes")
		type End = TxShapes.End
--]=]

local Fates = require("../Stored/Items/Fates")
local Names = require("../Encoding/Names")
local Post = require("../Stored/Post")

type Fate = Fates.Fate
type KeyReference = Names.KeyReference
type OpName = Names.OpName
type StoreKey = Names.StoreKey
type PathStep = Post.PathStep

export type TxLeg = {
	read Key: StoreKey,
	read OpKind: string,
	read Terms: unknown,
	read MustExist: boolean?,
	read Slot: { PathStep }?,
}

export type DeltaLeg = { read Kind: "Delta", read Field: string, read IsDebit: boolean, read Amount: unknown }

export type GameLeg = { read Kind: "Game", read Slot: { PathStep }? }

export type LegForm = DeltaLeg | GameLeg

export type TentForm = {
	read Kind: "Tent",
	read Name: OpName,
	read Attempt: number,
	read Leg: LegForm,
	read Decider: KeyReference,
}

export type CommitForm = {
	read Kind: "Commit",
	read Name: OpName,
	read Attempt: number,
	read Leg: LegForm,
	read OtherLegs: { KeyReference },
}

export type TxOutcome = "Commit" | "Abort" | "Orphan"

export type DroppedName = {
	read Name: OpName,
	read Stamp: number,
	read Proved: KeyReference?,
}

export type ResolveEnd = {
	read Kind: "Resolve",
	read Name: OpName,
	read Stamp: number,
	read Attempt: number,
	read Outcome: TxOutcome,
	read Decider: KeyReference,
	read DeciderValue: number?,
}

export type DropEnd = { read Kind: "Drop", read Names: { DroppedName } }

export type FenceEnd = {
	read Kind: "Fence",
	read Name: OpName,
	read Stamp: number,
	read Attempt: number,
	read IsFinal: boolean,
}

export type End = ResolveEnd | DropEnd | FenceEnd

export type TxReport =
	{ read Kind: "Mine", read Attempt: number }
	| { read Kind: "Superseded", read Attempt: number }
	| { read Kind: "Decided", read Fate: Fate }
	| { read Kind: "Other" }
	| { read Kind: "Refused", read Fate: Fate, read State: unknown }
	| { read Kind: "Large" }
	| { read Kind: "Committed", read Attempt: number, read DeciderValue: number? }
	| { read Kind: "Fenced", read Attempt: number, read IsFinal: boolean }
	| { read Kind: "Done" }
	| { read Kind: "Proved", read RemovalStamp: number, read Sealer: number }
	| { read Kind: "Exists" }

export type Carrier =
	{ read Kind: "Writer", read Key: StoreKey }
	| { read Kind: "Call", read CallId: number }
	| { read Kind: "Touch", read Key: StoreKey }
	| { read Kind: "Resettle", read CallId: number }
	| { read Kind: "Cut", read CallId: number }

export type HeldEnd = {
	read End: End,
	read CallId: number?,
	read Until: number?,
	read For: Carrier?,
}

export type AbortedUse = { read Name: OpName, read Attempt: number }

return {}
