--!strict
--!optimize 2

-- op log persistence, read a record, append ops idempotently by id, or compact them into a fresh snapshot

local NoYield = require("./Util/NoYield")
local TableUtil = require("./Util/TableUtil")
local DataStoreWrapper = require("./Util/DataStoreWrapper")
local Dedupe = require("./Dedupe")
local Fold = require("./Fold")
local Measure = require("./Measure")
local Reconcile = require("./Reconcile")
local Types = require("./Types")

type Op = Types.Op
type Record = Types.Record<any>
type Reducer = Types.Reducer<any>
type Migration = Types.Migration
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper

type Allow = (Record) -> boolean
type Step = (Record) -> Record?

export type Shape<S> = Types.Shape<S>
export type Log = Types.LogHandle
export type Outcome = Types.LogOutcome
export type Resolution = Types.LogResolution

local ENVELOPE = 1
local SEEN_LIMIT = 2048
local MAX_BYTES = 4 * 1024 * 1024
local WARN_BYTES = MAX_BYTES - 512 * 1024

local VERDICT = table.freeze({
	Prepared = "Prepared",
	Settled = "Settled",
	Busy = "Busy",
	Rejected = "Rejected"
})

local function Materialize(Value: any): Record
	if type(Value) ~= "table" then
		return { Ops = {}, Seen = {} }
	end

	if type(Value.Envelope) == "number" and Value.Envelope > ENVELOPE then
		error(`the record envelope is format {Value.Envelope} but this server only knows {ENVELOPE}, a newer framework wrote it`)
	end

	local Ops: { Op } = {}
	if type(Value.Ops) == "table" then
		for _, Op in Value.Ops do
			if type(Op) ~= "table" or type(Op.Id) ~= "string" then
				continue
			end
			local Loose = Op :: any
			if type(Loose.Kind) ~= "string" then
				continue
			end
			if Loose.Tx ~= nil and type(Loose.Tx) ~= "string" then
				continue
			end
			table.insert(Ops, Op :: Op)
		end
	end
	Value.Ops = Ops

	local Seen: { string } = {}
	if type(Value.Seen) == "table" then
		for _, Id in Value.Seen do
			if type(Id) == "string" then
				table.insert(Seen, Id)
			end
		end
	end
	Value.Seen = Seen

	if Value.Snapshot ~= nil and type(Value.Snapshot) ~= "table" then
		Value.Snapshot = nil
	end
	if type(Value.Version) ~= "number" then
		Value.Version = nil
	end
	if type(Value.Floor) ~= "number" then
		Value.Floor = nil
	end

	return Value
end

local function StepApply(Migration: Migration, State: any): any
	return NoYield(if type(Migration) == "function" then Migration else Migration.Apply, State)
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

local function HasPending(Record: Record): boolean
	for _, Op in Record.Ops do
		if Op.Tx ~= nil then
			return true
		end
	end
	return false
end

local function NotPending(Record: Record): boolean
	return not HasPending(Record)
end

local function PendingTx(Record: Record): { [string]: string | true }
	local Set: { [string]: string | true } = {}
	for _, Op in Record.Ops do
		if type(Op.Tx) == "string" then
			Set[Op.Tx] = if type(Op.TxHome) == "string" then Op.TxHome else true
		end
	end
	return Set
end

local function Hint(Snapshot: any): string
	if type(Snapshot) ~= "table" then
		return ""
	end

	local Name, Best = nil :: any, 0
	for Key, Value in Snapshot do
		local Size = Measure(Value)
		if Size > Best then
			Name, Best = Key, Size
		end
	end

	if Name == nil then
		return ""
	end
	return ` (largest field '{tostring(Name)}' at {Best} bytes)`
end

local function Missing(Record: Record, Ops: { Op }): { [string]: boolean }
	local Wanted: { [string]: boolean } = {}
	for _, Op in Ops do
		Wanted[Op.Id] = true
	end
	for _, Existing in Record.Ops do
		Wanted[Existing.Id] = nil
	end
	for _, Id in Record.Seen do
		Wanted[Id] = nil
	end
	return Wanted
end

local Shape = {} :: any
Shape.__index = Shape

function Shape.New<S>(Reducer: Types.Reducer<S>, Initial: S, Migrations: { Migration }?): Shape<S>
	return setmetatable({ Reducer = Reducer, Initial = Initial, Migrations = Migrations or {} }, Shape) :: any
end

function Shape.Floor(self: Shape<any>): number
	return FloorOf(self.Migrations)
end

function Shape.Rehydrate(self: Shape<any>, Record: Record): any
	if Record.Snapshot == nil then
		return self.Initial
	end

	local Steps = self.Migrations
	local Version = Record.Version or 0

	if Version > #Steps then
		local Floor = Record.Floor or Version
		if Floor > #Steps then
			error(`the record needs format version {Floor} but this server only knows {#Steps} migrations, a newer server wrote it`)
		end
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

function Shape.Fold(self: Shape<any>, Record: Record): any
	return Fold(self:Rehydrate(Record), Record.Ops, self.Reducer)
end

function Shape.Accepted(self: Shape<any>, Record: Record, Id: string): boolean
	local _, Took = Fold(self:Rehydrate(Record), Record.Ops, self.Reducer, Id)
	return Took
end

table.freeze(Shape)

local Log = {} :: any
Log.__index = Log

function Log.New(Wrapper: DataStoreWrapper): Log
	return setmetatable({ Wrapper = Wrapper }, Log) :: any
end

function Log.Update(self: Log, Key: string, Apply: Step): Outcome
	local Before: Record = nil :: any
	local Ok, Value = self.Wrapper:UpdateAsync(Key, function(Current: any): Record?
		Before = Materialize(Current)
		return Apply(Before)
	end)

	if not Ok then
		error(Value)
	end
	if Value == nil then
		return { Before = Before, After = Before, Changed = false }
	end
	return { Before = Before, After = Materialize(Value), Changed = true }
end

function Log.Read(self: Log, Key: string): Record
	local Ok, Value = self.Wrapper:GetAsync(Key)
	if not Ok then
		error(Value)
	end
	return Materialize(Value)
end

function Log.ReadVersion(self: Log, Key: string, Version: string): Record
	local Ok, Value = self.Wrapper:GetVersionAsync(Key, Version)
	if not Ok then
		error(Value)
	end
	return Materialize(Value)
end

function Log.Append(self: Log, Key: string, Ops: { Op }, Guard: Allow?): Record
	return self:Update(Key, function(Record: Record): Record?
		if Guard ~= nil and not Guard(Record) then
			return nil
		end

		local Wanted = Missing(Record, Ops)
		local Had = #Record.Ops
		for _, Op in Ops do
			if Wanted[Op.Id] then
				Wanted[Op.Id] = nil
				table.insert(Record.Ops, Op)
			end
		end
		if #Record.Ops == Had then
			return nil
		end

		Record.Envelope = ENVELOPE
		return Record
	end).After
end

function Log.AppendUnlessPending(self: Log, Key: string, Ops: { Op }): Record
	return self:Append(Key, Ops, NotPending)
end

function Log.Prepare(self: Log, Key: string, Op: Op, Format: Shape<any>): string
	local Verdict = VERDICT.Rejected
	self:Update(Key, function(Record: Record): Record?
		for _, Existing in Record.Ops do
			if Existing.Id == Op.Id then
				Verdict = if Existing.Tx == nil then VERDICT.Settled else VERDICT.Prepared
				return nil
			end
			if Existing.Tx ~= nil then
				Verdict = VERDICT.Busy
				return nil
			end
		end

		for _, Id in Record.Seen do
			if Id == Op.Id then
				Verdict = VERDICT.Settled
				return nil
			end
		end

		local View: Record = {
			Snapshot = if type(Record.Snapshot) == "table" then TableUtil.DeepCopy(Record.Snapshot) else nil,
			Ops = Record.Ops,
			Seen = Record.Seen,
			Version = Record.Version,
			Floor = Record.Floor
		}
		local State = Format:Fold(View)

		if type(Op.Tx) == "string" and Dedupe.Has(State._Received, Dedupe.TX, Op.Tx) then
			Verdict = VERDICT.Settled
			return nil
		end

		local Probe = table.clone(Op)
		Probe.Tx = nil
		Probe.TxHome = nil
		local Stepped, Next = pcall(NoYield, Format.Reducer, State, Probe :: Op)
		if not Stepped or type(Next) ~= "table" then
			Verdict = VERDICT.Rejected
			return nil
		end

		table.insert(Record.Ops, Op)
		Record.Envelope = ENVELOPE
		Verdict = VERDICT.Prepared
		return Record
	end)
	return Verdict
end

function Log.Resolve(self: Log, Key: string, Verdicts: { [string]: boolean }): Resolution
	local Counts: { [string]: number } = {}
	local Result = self:Update(Key, function(Record: Record): Record?
		table.clear(Counts)
		local Kept: { Op } = {}
		for _, Existing in Record.Ops do
			local Txid = Existing.Tx
			if type(Txid) == "string" and Verdicts[Txid] ~= nil then
				Counts[Txid] = (Counts[Txid] or 0) + 1
				if Verdicts[Txid] then
					local Live = table.clone(Existing)
					Live.Tx = nil
					Live.TxHome = nil
					table.insert(Kept, Live)
				end
			else
				table.insert(Kept, Existing)
			end
		end

		if next(Counts) == nil then
			return nil
		end

		Record.Ops = Kept
		Record.Envelope = ENVELOPE
		return Record
	end)

	return { Record = Result.After, Counts = Counts }
end

function Log.Compact(self: Log, Key: string, Format: Shape<any>): Record
	local Steps = Format.Migrations
	local KnownFloor = FloorOf(Steps)

	local Result = self:Update(Key, function(Record: Record): Record?
		if HasPending(Record) then
			return nil
		end
		local Base = Format:Rehydrate(Record)

		local Seen = table.clone(Record.Seen)
		for _, Op in Record.Ops do
			table.insert(Seen, Op.Id)
		end
		local Keep = math.max(SEEN_LIMIT, #Record.Ops)
		local Overflow = #Seen - Keep
		if Overflow > 0 then
			Seen = table.move(Seen, Overflow + 1, #Seen, 1, {})
		end

		local Stored = Record.Version or 0
		local Ahead = Stored > #Steps

		return {
			Envelope = ENVELOPE,
			Snapshot = Fold(Base, Record.Ops, Format.Reducer),
			Ops = {},
			Seen = Seen,
			Version = if Ahead then Stored else #Steps,
			Floor = if Ahead then Record.Floor or Stored else KnownFloor
		}
	end)

	if not Result.Changed then
		return Result.After
	end

	local Bytes = Measure(Result.After)
	if Bytes > WARN_BYTES then
		warn(`Ledger: key '{Key}' is {Bytes} bytes, near the {MAX_BYTES} byte datastore limit, saves will start failing if the data keeps growing{Hint(Result.After.Snapshot)}`)
	end
	return Result.After
end

table.freeze(Log)

return table.freeze({
	New = Log.New,
	Shape = Shape.New,
	Verdict = VERDICT,
	FloorOf = FloorOf,
	HasPending = HasPending,
	PendingTx = PendingTx
})
