--!strict
--!optimize 2

--[=[
	Op: The shapes that a datastore holds.

	Each tier agrees on these shapes. No module above may write them again.
	The envelope is the format of the record. A record with a higher envelope comes from a newer build.

	Return type: A table with ENVELOPE, MAX_VALUE_BYTES and MAX_STATE_BYTES. The types are Op, Record, HistoryEntry, KeyLike, KeysMode, Reducer and Migration.
	Example usage:
		local Contract = require("./Op")
		type Op = Contract.Op
--]=]

export type Op = {
	Id: string,
	Kind: string,
	[any]: any,
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

local MAX_VALUE_BYTES = 4 * 1024 * 1024
local MAX_STATE_BYTES = 2 * 1024 * 1024

return table.freeze({
	ENVELOPE = ENVELOPE,
	MAX_VALUE_BYTES = MAX_VALUE_BYTES,
	MAX_STATE_BYTES = MAX_STATE_BYTES,
})
