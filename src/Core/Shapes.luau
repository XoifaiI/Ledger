--!strict
--!optimize 2

--[=[

	Shapes: The shapes a datastore holds.

	An op, the record one key holds, and the state a fold gives back. Folded names Ledger's own four
	fields and leaves the game's own open. Held and Booked are one entry of the money set aside and
	the units set aside.

	Return type: A table with ENVELOPE. The types are Op, Record, HistoryEntry, KeyLike, KeysMode, Reducer, Migration, Held, Booked and Folded.
	Example usage:
		local Shapes = require("./Shapes")
		type Op = Shapes.Op
--]=]

export type Op = {
	Id: string,
	Kind: string,
	[any]: unknown,
}

export type Record<S> = {
	Snapshot: S?,
	Bytes: number?,
	Ops: { Op },
	Seen: { string },
	Version: number?,
	Floor: number?,
	Envelope: number?,
	Erased: number?,
}

export type HistoryEntry = {
	Version: string,
	At: number,
	Deleted: boolean,
}

export type KeysMode = "Player" | "String"

export type KeyLike = number | string

export type Held = {
	To: KeyLike,
	Amount: number,
	At: number?,
}

export type Booked = {
	Field: string,
	Amount: number,
	At: number,
	Hold: number?,
	To: string?,
	Handing: boolean?,
}

export type Folded = {
	_Held: { [string]: Held }?,
	_Booked: { [string]: Booked }?,
	_Received: { [string]: number | string }?,
	_Tally: { [string]: number }?,
	[any]: any,
}

export type Reducer<S> = (State: S, Op: Op) -> S?

export type Migration = ((State: any) -> any) | { Apply: (State: any) -> any, Compatible: boolean? }

local ENVELOPE = 1

return table.freeze({
	ENVELOPE = ENVELOPE,
})
