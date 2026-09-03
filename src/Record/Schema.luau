--!strict
--!optimize 2

--[=[

	Schema: Turns a stored record into the state a game reads.

	Migrations run first. Defaults fill in second. The ops fold on top of the snapshot last.

	A migration is the game's code, and Ledger does not trust it with its own fields. Schema puts back
	every field starting with an underscore after every step, and names the step that dropped one.
	Certain says whether a parked transaction can still change the answer. Detached copies the
	snapshot, so a reducer cannot reach the stored record through it.

	Return type: A table with New, FloorOf, Migrate and Detached.
	Example usage:
		local Schema = require("./Schema")
		local Format = Schema.New(Reducer, Initial, Steps)
--]=]

local NoYield = require("../Util/NoYield")
local TableUtil = require("../Util/TableUtil")
local Errors = require("../Core/Errors")
local Reasons = require("../Core/Constants/Reasons")
local Shapes = require("../Core/Shapes")
local Storable = require("../Encode/Storable")
local Fold = require("./Fold")
local Reconcile = require("./Reconcile")
local TxStamp = require("./TxStamp")
local Types = require("./Types")

type Record = Shapes.Record<any>
type Migration = Shapes.Migration

export type Schema<S> = Types.Shape<S>

local function StepApply(Migration: Migration, State: any): any
	return NoYield.Run(if type(Migration) == "function" then Migration else Migration.Apply, State)
end

local function Bookkeeping(Snapshot: any): { [string]: any }?
	local Kept: { [string]: any }? = nil
	for Key, Value in Snapshot do
		if type(Key) == "string" and Storable.Bookkeeping(Key) then
			Kept = Kept or {}
			(Kept :: { [string]: any })[Key] = Value
		end
	end
	return Kept
end

local function Restored(Snapshot: any, Kept: { [string]: any }?, Index: number): any
	if Kept == nil then
		return Snapshot
	end

	local Next = Snapshot
	for Key, Value in Kept do
		local Theirs = Next[Key]
		if Theirs == Value then
			continue
		end

		if Next == Snapshot then
			Next = table.clone(Snapshot)
		end
		Next[Key] = Value
		if TableUtil.DeepEqual(Theirs, Value) then
			continue
		end
		warn(`Ledger: migration {Index} dropped Ledger's own '{Key}'. Ledger put it back, leave fields starting with an underscore alone`)
	end
	return Next
end

local function Migrate(Steps: { Migration }, Snapshot: any, From: number): any?
	local State = Snapshot
	for Index = From + 1, #Steps do
		State = StepApply(Steps[Index], State)
		if type(State) ~= "table" then
			return nil
		end
	end
	return State
end

local function FloorOf(Steps: { Migration }): number
	for Index = #Steps, 1, -1 do
		local Migration = Steps[Index]
		if type(Migration) == "function" or not Migration.Compatible then
			return Index
		end
	end
	return 0
end

local function Detached(Record: Record): Record
	return {
		Snapshot = if type(Record.Snapshot) == "table" then TableUtil.DeepCopy(Record.Snapshot) else nil,
		Ops = Record.Ops,
		Seen = Record.Seen,
		Version = Record.Version,
		Floor = Record.Floor,
	}
end

local Blobbed: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function AnyBuffer(Value: any): boolean
	if type(Value) == "buffer" then
		return true
	end
	if type(Value) ~= "table" then
		return false
	end

	for _, Inner in Value do
		if AnyBuffer(Inner) then
			return true
		end
	end
	return false
end

local Schema = {} :: Types.ShapeImpl<any>
Schema.__index = Schema

function Schema.New<S>(Reducer: Shapes.Reducer<S>, Initial: S, Migrations: { Migration }?, Handles: { [string]: boolean }?): Schema<S>
	local Blobs = Blobbed[Initial :: any]
	if Blobs == nil then
		Blobs = AnyBuffer(Initial)
		Blobbed[Initial :: any] = Blobs
	end

	return setmetatable({
		Reducer = Reducer,
		Initial = Initial,
		Migrations = Migrations or {},
		Handles = Handles,
		Blobbed = Blobs,
	}, Schema) :: any
end

function Schema.Rehydrate(self: Schema<any>, Record: Record): any
	local Steps = self.Migrations
	local Version = Record.Version or 0

	local Held = Record.Floor
	local Needs = if type(Held) == "number" then Held elseif Version > #Steps then Version else 0
	if Needs > #Steps then
		Errors.Raise(Reasons.Behind, `this record needs {Needs} migrations and this server has {#Steps}, a newer build wrote it. finish the deploy`)
	end

	if Record.Snapshot == nil then
		return if self.Blobbed then TableUtil.DeepCopy(self.Initial) else self.Initial
	end

	if Version > #Steps then
		return Reconcile(self.Initial, Record.Snapshot)
	end

	local Snapshot = Record.Snapshot
	local Kept = if Version < #Steps then Bookkeeping(Snapshot) else nil
	for Index = Version + 1, #Steps do
		Snapshot = StepApply(Steps[Index], Snapshot)
		if type(Snapshot) ~= "table" then
			error(`migration {Index} returned a {typeof(Snapshot)} instead of the migrated state`)
		end
		Snapshot = Restored(Snapshot, Kept, Index)
	end

	return Reconcile(self.Initial, Snapshot)
end

function Schema.Fold(self: Schema<any>, Record: Record): any
	return Fold(self:Rehydrate(Record), Record.Ops, self.Reducer)
end

function Schema.Certain(self: Schema<any>, Record: Record, Id: string): (boolean, boolean)
	local Base = self:Rehydrate(Record)
	local _, Took = Fold(Base, Record.Ops, self.Reducer, Id)

	local Pending = TxStamp.PendingTx(Record)
	local Count = TableUtil.Count(Pending)
	if Count == 0 then
		return Took, true
	end
	if Count > 1 then
		return Took, false
	end

	local _, Also = Fold(Base, TxStamp.Landed(Record.Ops, next(Pending) :: string), self.Reducer, Id)
	return Took, Took == Also
end

table.freeze(Schema)

return table.freeze({
	New = Schema.New,
	FloorOf = FloorOf,
	Migrate = Migrate,
	Detached = Detached,
})
