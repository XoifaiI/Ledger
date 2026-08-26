--!strict
--!optimize 2

--[=[
	Op: The shapes that a datastore holds.

	Each tier agrees on these shapes. No module above may write them again.
	The envelope is the format of the record. A record with a higher envelope comes from a newer build.

	Return type: A table with ENVELOPE. The types are Op, Record, HistoryEntry, KeyLike, KeysMode, Reducer and Migration.
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

export type Reducer<S> = (State: S, Op: Op) -> S?

export type Migration = ((State: any) -> any) | { Apply: (State: any) -> any, Compatible: boolean? }

local ENVELOPE = 1

return table.freeze({
	ENVELOPE = ENVELOPE,
})
