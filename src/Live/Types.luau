--!strict
--!optimize 2

--[=[
	Types: The session declarations.

	These are private to this folder. This file holds declarations, and never logic.
	A ruling has three outcomes, and not a boolean with a reason beside it. Rejected is the reducer
	that says no, which is not a failure, and only Accepted carries a next state.

	Return type: An empty table. The types are Admitted, SessionImpl and Session.
	Example usage:
		local Types = require("./Types")
		type Session<S> = Types.Session<S>
--]=]

local Future = require("../Util/Future")
local Observer = require("../Util/Observer")
local DataStoreWrapper = require("../Util/DataStoreWrapper")
local Contract = require("../Contract/Op")
local Reasons = require("../Contract/Reason")
local LogTypes = require("../Record/Types")

type Future<T...> = Future.Future<T...>
type Observer<T> = Observer.Observer<T>
type Subject<T> = Observer.Subject<T>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Op = Contract.Op
type Record<S> = Contract.Record<S>
type Reason = Reasons.Reason

export type Admitted<S> = { read Outcome: "Refused", read Why: Reason } | { read Outcome: "Rejected" } | { read Outcome: "Accepted", read Next: S, read Bytes: number?, read Also: S? }

export type SessionImpl<S> = {
	__index: SessionImpl<S>,

	Settled: (self: Session<S>, Stored: Record<any>) -> Record<any>,
	Notify: (self: Session<S>) -> (),

	Get: (self: Session<S>) -> S,
	Apply: (self: Session<S>, Kind: string, Fields: { [any]: any }?) -> (boolean, Reason?),
	Commit: (self: Session<S>, Kind: string, Fields: { [any]: any }?) -> Future<boolean, Reason?>,
	CommitOp: (self: Session<S>, Op: Op) -> Future<boolean, Reason?>,
	Flush: (self: Session<S>) -> Future<boolean, Reason?>,
	Compact: (self: Session<S>) -> Future<boolean, Reason?>,
	Release: (self: Session<S>) -> Future<boolean, Reason?>,
	Observe: (self: Session<S>) -> Observer<S>,
	DidApply: (self: Session<S>, Id: string) -> boolean,
}

export type Session<S> = setmetatable<{
	Log: LogTypes.Log,
	Shape: LogTypes.Shape<S>,
	Key: string,
	TxStore: DataStoreWrapper?,
	State: S,
	Landed: S?,
	Fence: number?,
	Parked: number,
	Applied: { [string]: boolean },
	Pending: { Op },
	LogSize: number,
	LogBytes: number,
	StateBytes: number,
	Changed: Subject<S>,
	Released: boolean,
}, SessionImpl<S>>

return table.freeze({})
