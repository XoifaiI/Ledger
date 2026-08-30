--!strict
--!optimize 2

--[=[

	Schema: Turns a stored record into the state a game reads.

	Migrations run first, defaults are filled in second, and the ops fold on top of the snapshot last.
	Certain says whether a parked transaction can still change the answer. Detached copies the
	snapshot, so a reducer cannot reach the stored record through it.

	Return type: A table with New, FloorOf, Migrate and Detached.
	Example usage:
		local Schema = require("./Schema")
		local Format = Schema.New(Reducer, Initial, Steps)
--]=]

local NoYield = require("../Util/NoYield")
local TableUtil = require("../Util/TableUtil")
local Reasons = require("../Core/Constants/Reasons")
local Shapes = require("../Core/Shapes")
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
	if Record.Snapshot == nil then
		return if self.Blobbed then TableUtil.DeepCopy(self.Initial) else self.Initial
	end

	local Steps = self.Migrations
	local Version = Record.Version or 0

	local Held = Record.Floor
	local Needs = if type(Held) == "number" then Held elseif Version > #Steps then Version else 0
	if Needs > #Steps then
error({
			Ledger = true,
			Why = Reasons.Behind,
			Message = `the record needs format version {Needs} but this server only knows {#Steps} migrations, a newer server wrote it`,
		})
	end

	if Version > #Steps then
		return Reconcile(self.Initial, Record.Snapshot)
	end

	local Snapshot = Record.Snapshot
	for Index = Version + 1, #Steps do
		Snapshot = StepApply(Steps[Index], Snapshot)
		if type(Snapshot) ~= "table" then
			error(`migration {Index} returned a {typeof(Snapshot)} instead of the migrated state`)
		end
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
