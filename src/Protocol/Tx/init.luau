--!strict
--!optimize 2

--[=[

	Tx: The transaction protocol under one name.

	A caller above this tier does not have to know which half of the protocol owns what.

	Return type: A table with Drive, Settle, Reap and ShutdownHomes.
	Example usage:
		local Tx = require("../Protocol/Tx")
		local Ok, Why = Tx.Drive(TxStore, Legs, "trade1")
--]=]

local Coordinator = require("@self/Coordinator")
local Marker = require("@self/Marker")
local Reap = require("@self/Reap")
local Resolve = require("@self/Resolve")
local Types = require("@self/Types")

export type Leg = Types.Leg
export type Status = Types.Status
export type Lookup = Types.Lookup
export type Claimed = Types.Claimed

return table.freeze({
	Drive = Coordinator.Drive,
	Settle = Resolve.Settle,
	Reap = Reap.Reap,
	ShutdownHomes = Marker.ShutdownHomes,
})
