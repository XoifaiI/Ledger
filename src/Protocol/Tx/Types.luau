--!strict
--!optimize 2

--[=[

	Types: The marker and leg declarations of the transaction protocol.

	These are private to this folder. This file holds declarations, and never logic.

	Return type: An empty table. The types are Status, Opened, Marker, Leg, Pass, Lookup and Claimed.
	Example usage:
		local Types = require("./Types")
		type Leg = Types.Leg
--]=]

local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local Reasons = require("../../Core/Constants/Reasons")
local Transactions = require("../../Core/Constants/Transactions")
local LogTypes = require("../../Record/Types")

type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Reason = Reasons.Reason

export type Status = Transactions.Status

export type Opened = Transactions.Opened

export type Marker = {
	Status: Status,
	Total: number,
	Gen: string?,
	At: number?,
	Adopted: { [string]: boolean }?,
	Keys: string?,
	Terms: string?,
	Dead: boolean?,
}

export type Leg = {
	Key: string,
	Kind: string,
	Fields: { [any]: any }?,
	Log: LogTypes.Log,
	Shape: LogTypes.Shape<any>,
	TxStore: DataStoreWrapper,
}

export type Pass = {
	read Committed: boolean,
	read Why: Reason?,
	read Again: boolean,
	read Reached: number,
	read Parked: boolean,
}

export type Lookup = (Name: string) -> LogTypes.Log?

export type Claimed = { read Outcome: "Taken", read Release: () -> () } | { read Outcome: "Held" } | { read Outcome: "Unknown" }

return table.freeze({})
