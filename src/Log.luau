--!strict
--!optimize 2

--[=[
    Log: op log persistence, read the stored record, append ops idempotently by id, or
    compact the ops into a fresh snapshot. all through the retrying wrapper, yields and
    throws on failure.

    Rehydrate runs the migrations on an older snapshot before the fold. a record newer than
    this server knows loads untouched only if every step past its knowledge was Compatible
    (the Floor names the minimum a reader must know), and refuses otherwise, so a stale
    server can never fold an incompatible future format down. the record envelope carries its
    own format number too, so a future restructure is never misread as an empty record. see
    docs/migrations.md for the rolling-deploy reasoning.

    Return type: frozen table { Read, ReadVersion, Append, Compact, Rehydrate, FoldRecord }
    Example usage:
        local Record = Log.Read(Wrapper, Key)
        local State = Log.FoldRecord(Record, Initial, Reducer)
--]=]

local NoYield = require("./Util/NoYield")
local DataStoreWrapper = require("./Util/DataStoreWrapper")
local Fold = require("./Fold")
local Measure = require("./Measure")
local Reconcile = require("./Reconcile")
local Types = require("./Types")

type Op = Types.Op
type Record<S> = Types.Record<S>
type Reducer<S> = Types.Reducer<S>
type Migration = Types.Migration
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper

local ENVELOPE = 1
local SEEN_LIMIT = 2048

local MAX_BYTES = 4 * 1024 * 1024
local WARN_BYTES = MAX_BYTES - 512 * 1024

local function Materialize(Value: any): Record<any>
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

local function StepApply(Step: Migration, State: any): any
	return if type(Step) == "function" then Step(State) else Step.Apply(State)
end

local function FloorOf(Steps: { Migration }): number
	for Index = #Steps, 1, -1 do
		local Step = Steps[Index]
		if type(Step) == "function" or not Step.Compatible then
			return Index
		end
	end
	return 0
end

local function Rehydrate<S>(Record: Record<any>, Initial: S, Migrations: { Migration }?): S
	if Record.Snapshot == nil then
		return Initial
	end

	local Steps = Migrations or {}
	local Version = Record.Version or 0

	if Version > #Steps then
		local Floor = Record.Floor or Version
		if Floor > #Steps then
			error(`the record needs format version {Floor} but this server only knows {#Steps} migrations, a newer server wrote it`)
		end
		return Reconcile(Initial, Record.Snapshot) :: S
	end

	local Snapshot = Record.Snapshot
	for Index = Version + 1, #Steps do
		Snapshot = StepApply(Steps[Index], Snapshot)
		if type(Snapshot) ~= "table" then
			error(`migration {Index} returned a {typeof(Snapshot)} instead of the migrated state`)
		end
	end

	return Reconcile(Initial, Snapshot) :: S
end

local function FoldRecord<S>(Record: Record<any>, Initial: S, Reducer: Reducer<S>, Migrations: { Migration }?): S
	return Fold(Rehydrate(Record, Initial, Migrations), Record.Ops, Reducer)
end

local function Read(Wrapper: DataStoreWrapper, Key: string): Record<any>
	local Ok, Value = Wrapper:GetAsync(Key)
	if not Ok then
		error(Value)
	end
	return Materialize(Value)
end

local function ReadVersion(Wrapper: DataStoreWrapper, Key: string, Version: string): Record<any>
	local Ok, Value = Wrapper:GetVersionAsync(Key, Version)
	if not Ok then
		error(Value)
	end
	return Materialize(Value)
end

local function AppendImpl(Wrapper: DataStoreWrapper, Key: string, Ops: { Op }, RejectIfPending: boolean?): Record<any>
	local Unchanged: Record<any>? = nil
	local Ok, Value = Wrapper:UpdateAsync(Key, function(Current: any): Record<any>?
		local Record = Materialize(Current)

		if RejectIfPending then
			for _, Existing in Record.Ops do
				if Existing.Tx ~= nil then
					Unchanged = Record
					return nil
				end
			end
		end

		local Present: { [string]: boolean } = {}
		for _, Existing in Record.Ops do
			Present[Existing.Id] = true
		end
		for _, Id in Record.Seen do
			Present[Id] = true
		end

		local Added = false
		for _, Op in Ops do
			if not Present[Op.Id] then
				Present[Op.Id] = true
				table.insert(Record.Ops, Op)
				Added = true
			end
		end

		if not Added then
			Unchanged = Record
			return nil
		end

		Record.Envelope = ENVELOPE
		return Record
	end)

	if not Ok then
		error(Value)
	end
	if Value == nil then
		return Unchanged :: Record<any>
	end
	return Materialize(Value)
end

local function Append(Wrapper: DataStoreWrapper, Key: string, Ops: { Op }): Record<any>
	return AppendImpl(Wrapper, Key, Ops, false)
end

local function AppendUnlessPending(Wrapper: DataStoreWrapper, Key: string, Ops: { Op }): Record<any>
	return AppendImpl(Wrapper, Key, Ops, true)
end

local function PendingTx(Record: Record<any>): { [string]: string | true }
	local Set: { [string]: string | true } = {}
	for _, Op in Record.Ops do
		if type(Op.Tx) == "string" then
			Set[Op.Tx] = if type(Op.TxHome) == "string" then Op.TxHome else true
		end
	end
	return Set
end

local function HasPending(Record: Record<any>): boolean
	for _, Op in Record.Ops do
		if Op.Tx ~= nil then
			return true
		end
	end
	return false
end

local function Prepare<S>(Wrapper: DataStoreWrapper, Key: string, Op: Op, Reducer: Reducer<S>, Initial: S, Migrations: { Migration }?): string
	local Verdict = "Rejected"
	local Ok, Value = Wrapper:UpdateAsync(Key, function(Current: any): Record<any>?
		local Record = Materialize(Current)

		for _, Existing in Record.Ops do
			if Existing.Id == Op.Id then
				Verdict = "Prepared"
				return nil
			end
			if Existing.Tx ~= nil then
				Verdict = "Busy"
				return nil
			end
		end
		for _, Id in Record.Seen do
			if Id == Op.Id then
				Verdict = "Aborted"
				return nil
			end
		end

		local State = Fold(Rehydrate(Record, Initial, Migrations), Record.Ops, Reducer)
		local Probe = table.clone(Op)
		Probe.Tx = nil
		Probe.TxHome = nil
		local Stepped, Next = pcall(NoYield, Reducer, State, Probe :: Op)
		if not Stepped or type(Next) ~= "table" then
			Verdict = "Rejected"
			return nil
		end

		table.insert(Record.Ops, Op)
		Record.Envelope = ENVELOPE
		Verdict = "Prepared"
		return Record
	end)

	if not Ok then
		error(Value)
	end
	return Verdict
end

local function Resolve(Wrapper: DataStoreWrapper, Key: string, Verdicts: { [string]: boolean }): (Record<any>, { [string]: number })
	local Counts: { [string]: number } = {}
	local Unchanged: Record<any>? = nil
	local Ok, Value = Wrapper:UpdateAsync(Key, function(Current: any): Record<any>?
		table.clear(Counts)
		local Record = Materialize(Current)

		local Kept: { Op } = {}
		local Changed = false
		for _, Existing in Record.Ops do
			local Txid = Existing.Tx
			if type(Txid) == "string" and Verdicts[Txid] ~= nil then
				Changed = true
				Counts[Txid] = (Counts[Txid] or 0) + 1
				if Verdicts[Txid] then
					local Live = table.clone(Existing)
					Live.Tx = nil
					Live.TxHome = nil
					table.insert(Kept, Live)
				else
					table.insert(Record.Seen, Existing.Id)
				end
			else
				table.insert(Kept, Existing)
			end
		end

		if not Changed then
			Unchanged = Record
			return nil
		end
		Record.Ops = Kept
		Record.Envelope = ENVELOPE
		return Record
	end)

	if not Ok then
		error(Value)
	end
	if Value == nil then
		return Unchanged :: Record<any>, Counts
	end
	return Materialize(Value), Counts
end

local function Largest(Snapshot: any): (string?, number)
	if type(Snapshot) ~= "table" then
		return nil, 0
	end
	local Name: string?, Best = nil, 0
	for Key, Value in Snapshot do
		if type(Key) == "string" then
			local Size = Measure(Value)
			if Size > Best then
				Name, Best = Key, Size
			end
		end
	end
	return Name, Best
end

local function Compact<S>(Wrapper: DataStoreWrapper, Key: string, Reducer: Reducer<S>, Initial: S, Migrations: { Migration }?): Record<any>
	local Steps = Migrations or {}
	local KnownFloor = FloorOf(Steps)
	local Skipped: Record<any>? = nil
	local Ok, Value = Wrapper:UpdateAsync(Key, function(Current: any): Record<any>?
		local Record = Materialize(Current)
		if HasPending(Record) then
			Skipped = Record
			return nil
		end
		local Base = Rehydrate(Record, Initial, Steps)

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
		local Future = Stored > #Steps

		return {
			Envelope = ENVELOPE,
			Snapshot = Fold(Base, Record.Ops, Reducer),
			Ops = {},
			Seen = Seen,
			Version = if Future then Stored else #Steps,
			Floor = if Future then Record.Floor or Stored else KnownFloor,
		}
	end)

	if not Ok then
		error(Value)
	end
	if Value == nil then
		return Skipped :: Record<any>
	end

	local Record = Materialize(Value)
	local Bytes = Measure(Record)
	if Bytes > WARN_BYTES then
		local Field, FieldBytes = Largest(Record.Snapshot)
		local Hint = if Field then ` (largest field '{Field}' at {FieldBytes} bytes)` else ""
		warn(`Ledger: key '{Key}' is {Bytes} bytes, near the {MAX_BYTES} byte datastore limit, saves will start failing if the data keeps growing{Hint}`)
	end
	return Record
end

return table.freeze({
	Read = Read,
	ReadVersion = ReadVersion,
	Append = Append,
	AppendUnlessPending = AppendUnlessPending,
	Compact = Compact,
	Rehydrate = Rehydrate,
	FoldRecord = FoldRecord,
	Prepare = Prepare,
	Resolve = Resolve,
	PendingTx = PendingTx,
	HasPending = HasPending,
})
