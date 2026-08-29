--!strict
--!optimize 2

--[=[
	Types: The log and shape declarations.

	These are private to this folder. This file holds declarations, and never logic.

	Return type: An empty table. The types are Outcome, Resolution, Verdict, Prepared, Fated, Shape and Log.
	Example usage:
		local Types = require("./Types")
		type Log = Types.Log
--]=]

local DataStoreWrapper = require("../Util/DataStoreWrapper")
local Shapes = require("../Core/Shapes")

type Op = Shapes.Op
type Record<S> = Shapes.Record<S>
type Reducer<S> = Shapes.Reducer<S>
type Migration = Shapes.Migration
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper

export type Outcome = { Before: Record<any>, After: Record<any>, Changed: boolean }

export type Resolution = { Record: Record<any>, Counts: { [string]: number } }

export type Verdict = { Commit: boolean, Gen: string?, Since: number? }

export type Prepared = "Prepared" | "Settled" | "Busy" | "Rejected" | "Spent" | "Full"

export type Fated = "Owned" | "Dead"

export type ShapeImpl<S> = {
	__index: ShapeImpl<S>,

	New: (Reducer: Reducer<S>, Initial: S, Migrations: { Migration }?, Handles: { [string]: boolean }?) -> Shape<S>,
	Rehydrate: (self: Shape<S>, Record: Record<any>) -> S,
	Fold: (self: Shape<S>, Record: Record<any>) -> S,
	Certain: (self: Shape<S>, Record: Record<any>, Id: string) -> (boolean, boolean),
}

export type Shape<S> = setmetatable<{
	read Reducer: Reducer<S>,
	read Initial: S,
	read Migrations: { Migration },
	read Handles: { [string]: boolean }?,
	read Blobbed: boolean,
}, ShapeImpl<S>>

export type LogImpl = {
	__index: LogImpl,

	New: (Wrapper: DataStoreWrapper, Known: number?, Floor: number?) -> Log,
	Legible: (self: Log, Key: string, Record: Record<any>) -> (),
	Update: (self: Log, Key: string, Apply: (Record<any>) -> Record<any>?) -> Outcome,
	Read: (self: Log, Key: string) -> Record<any>,
	ReadVersion: (self: Log, Key: string, Version: string) -> Record<any>,
	Append: (self: Log, Key: string, Ops: { Op }, Guard: ((Record<any>) -> boolean)?, Sift: ((Record<any>) -> (Op) -> boolean)?) -> (Record<any>, { string }),
	AppendUnlessPending: (self: Log, Key: string, Ops: { Op }) -> Record<any>,
	Entomb: (self: Log, Key: string, At: number, Bury: ((Record<any>) -> Record<any>)?) -> Record<any>,
	Prepare: (self: Log, Key: string, Op: Op, Format: Shape<any>) -> Prepared,
	Resolve: (self: Log, Key: string, Verdicts: { [string]: Verdict }) -> Resolution,
	Compact: (self: Log, Key: string, Format: Shape<any>) -> Record<any>,
	Trim: (self: Log, Key: string, Format: Shape<any>, Record: Record<any>) -> Record<any>,
}

export type Log = setmetatable<{
	read Wrapper: DataStoreWrapper,
	read Known: number?,
	read Floor: number?,
}, LogImpl>

return table.freeze({})
