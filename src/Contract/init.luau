--!strict
--!optimize 2

--[=[
	Contract: The shared words of Ledger, under one name.
	
	Use this when a module needs more than one part. A module that needs one part requires that one file.
	The list of requires then tells you what the module depends on.
	
	Return type: A table with Fault and Reasons.
	Example usage:
		local Contract = require("../Contract")
		type Reason = Contract.Reason
--]=]

local Fault = require("@self/Fault")
local Op = require("@self/Op")
local Public = require("@self/Public")
local Reasons = require("@self/Reason")

export type Fault = Fault.Fault

export type Op = Op.Op
export type Record<S> = Op.Record<S>
export type HistoryEntry = Op.HistoryEntry
export type KeysMode = Op.KeysMode
export type KeyLike = Op.KeyLike
export type Reducer<S> = Op.Reducer<S>
export type Migration = Op.Migration

export type Reason = Reasons.Reason

export type TxLeg = Public.TxLeg
export type HoldOptions = Public.HoldOptions
export type Live<S> = Public.Live<S>
export type Store<D> = Public.Store<D>
export type Config<D> = Public.Config<D>

return table.freeze({
	Fault = Fault,
	Reasons = Reasons
})
