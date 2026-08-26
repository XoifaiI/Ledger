--!strict
--!optimize 2

--[=[
	Tx: The transaction protocol under one name.

	A caller above this tier does not have to know which half of the protocol owns what.

	Return type: A table with Drive, Settle, Reap, ShutdownHomes, RESERVED, LEG_TIMEOUT, TIMEOUT, MAX_LEGS, REAP_HORIZON, REAP_GRACE, REAP_LOOKS, REAP_PAGE, SHARDS and Roll.
	Example usage:
		local Tx = require("../Protocol/Tx")
		local Ok, Why = Tx.Drive(TxStore, Legs, "trade1")
--]=]

local Drive = require("@self/Drive")
local Marker = require("@self/Marker")
local Reap = require("@self/Reap")
local Roll = require("@self/Roll")
local Settle = require("@self/Settle")
local Types = require("@self/Types")

export type Leg = Types.Leg
export type Status = Types.Status
export type Lookup = Types.Lookup

return table.freeze({
	Drive = Drive.Drive,
	Settle = Settle.Settle,
	Reap = Reap.Reap,
	ShutdownHomes = Marker.ShutdownHomes,

	RESERVED = Roll.RESERVED,

	LEG_TIMEOUT = Drive.LEG_TIMEOUT,
	TIMEOUT = Drive.TIMEOUT,
	MAX_LEGS = Drive.MAX_LEGS,
	REAP_HORIZON = Reap.REAP_HORIZON,
	REAP_LOOKS = Reap.REAP_LOOKS,
	REAP_PAGE = Reap.REAP_PAGE,
	REAP_GRACE = Reap.REAP_GRACE,
	REAP_FLOOR = Reap.REAP_FLOOR,
	SHARDS = Roll.SHARDS,
	Roll = Roll,
})
