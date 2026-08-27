--!strict
--!optimize 2

--[=[
	Op: The shapes that a datastore holds.

	Each tier agrees on these shapes. No module above may write them again.
	The envelope is the format of the record. A record with a higher envelope comes from a newer build.
	Folded is the state a fold gives back, with Ledger's four fields named and the game's own left
	open. Held and Booked are one entry of the first two, named here so the layer that writes one and
	the protocol that reads it cannot drift. A record comes back from a datastore, so Escrow.Entry and
	Booking.Entry guard one on the way out, and a hold an older build wrote carries no At.

	Return type: A table with ENVELOPE. The types are Op, Record, HistoryEntry, KeyLike, KeysMode, Reducer, Migration, Held, Booked and Folded.
	Example usage:
		local Contract = require("./Op")
		type Op = Contract.Op
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
