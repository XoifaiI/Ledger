--!strict
--!optimize 2

--[=[

	Tx: The transaction protocol under one name.

	A caller above this tier does not have to know which half of the protocol owns what.

	Return type: A table with Drive, Settle, Reap, ShutdownHomes, RESERVED, MAX_LEGS, REAP_LOOKS, REAP_PAGE, REAP_FLOOR, SHARDS and Roll.
	Example usage:
		local Tx = require("../Protocol/Tx")
		local Ok, Why = Tx.Drive(TxStore, Legs, "trade1")
--]=]

local Coordinator = require("@self/Coordinator")
local Marker = require("@self/Marker")
local Reap = require("@self/Reap")
local Cleanup = require("@self/Cleanup")
local Resolve = require("@self/Resolve")
local Types = require("@self/Types")

export type Leg = Types.Leg
export type Status = Types.Status
export type Lookup = Types.Lookup

return table.freeze({
	Drive = Coordinator.Drive,
	Settle = Resolve.Settle,
	Reap = Reap.Reap,
	ShutdownHomes = Marker.ShutdownHomes,

	RESERVED = Cleanup.RESERVED,

	MAX_LEGS = Coordinator.MAX_LEGS,
	REAP_LOOKS = Reap.REAP_LOOKS,
	REAP_PAGE = Reap.REAP_PAGE,
	REAP_FLOOR = Reap.REAP_FLOOR,
	SHARDS = Cleanup.SHARDS,
	Roll = Cleanup,
})
