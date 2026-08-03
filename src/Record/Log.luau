--!strict
--!optimize 2

-- op log persistence, read a record, append ops idempotently by id, or compact them into a fresh snapshot

local NoYield = require("../Util/NoYield")
local TableUtil = require("../Util/TableUtil")
local DataStoreWrapper = require("../Util/DataStoreWrapper")
local Fault = require("../Fault")
local Reasons = require("../Reason")
local Dedupe = require("./Dedupe")
local Fold = require("./Fold")
local Measure = require("./Measure")
local Reconcile = require("./Reconcile")
local Step = require("./Step")
local IsStorable = require("./Storable")
local Types = require("../Types")

type Op = Types.Op
type Record = Types.Record<any>
type Reducer = Types.Reducer<any>
type Migration = Types.Migration
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper

type Allow = (Record) -> boolean
type Transform = (Record) -> Record?

export type Shape<S> = Types.Shape<S>
export type Log = Types.LogHandle
export type Outcome = Types.LogOutcome
export type Resolution = Types.LogResolution
export type Verdict = Types.LogVerdict
export type Prepared = Types.LogPrepared
export type Fated = Types.LogFated

local ENVELOPE = 1
local SEEN_LIMIT = 2048
local MAX_BYTES = 4 * 1024 * 1024
local WARN_BYTES = MAX_BYTES - 512 * 1024

local COMPACT_OPS = 128
local COMPACT_BYTES = 1024 * 1024
local MAX_LOG_BYTES = 1536 * 1024

local OWNED: Fated = "Owned"
local DEAD: Fated = "Dead"

local VERDICT = table.freeze({
	Prepared = "Prepared" :: Prepared,
	Settled = "Settled" :: Prepared,
	Busy = "Busy" :: Prepared,
	Rejected = "Rejected" :: Prepared,
	Spent = "Spent" :: Prepared
})

local function Materialize(Value: any): Record
	if type(Value) ~= "table" then
		return { Ops = {}, Seen = {} }
	end

	if type(Value.Envelope) == "number" and Value.Envelope > ENVELOPE then
		error(Fault.New(Reasons.Behind, `the record envelope is format {Value.Envelope} but this server only knows {ENVELOPE}, a newer framework wrote it`))
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
	if type(Value.Erased) ~= "number" then
		Value.Erased = nil
	end
	if type(Value.Floor) ~= "number" then
		Value.Floor = nil
	end

	return Value
end

local function StepApply(Migration: Migration, State: any): any
	return NoYield(if type(Migration) == "function" then Migration else Migration.Apply, State)
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

local function Oversized(Ops: number, Bytes: number): boolean
	return Ops >= COMPACT_OPS or Bytes >= COMPACT_BYTES
end

local function Overgrown(Record: Record): boolean
	if #Record.Ops >= COMPACT_OPS then
		return true
	end
	return Measure(Record.Ops) >= COMPACT_BYTES
end

local function Detached(Record: Record): Record
	return {
		Snapshot = if type(Record.Snapshot) == "table" then TableUtil.DeepCopy(Record.Snapshot) else nil,
		Ops = Record.Ops,
		Seen = Record.Seen,
		Version = Record.Version,
		Floor = Record.Floor
	}
end

local function Unstamped(Op: Op): Op
	local Plain = table.clone(Op)
	Plain.Tx = nil
	Plain.TxHome = nil
	Plain.TxGen = nil
	return Plain
end

local function Landed(Ops: { Op }, Txid: string?): { Op }
	local Out = table.clone(Ops)
	for Index, Existing in Out do
		if Existing.Tx ~= nil and (Txid == nil or Existing.Tx == Txid) then
			Out[Index] = Unstamped(Existing)
		end
	end
	return Out
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

local function Holds(Record: Record, Id: string): boolean
	for _, Op in Record.Ops do
		if Op.Id == Id then
			return true
		end
	end
	return false
end

local function Meant(Held: any, Wanted: any): boolean
	return type(Held) ~= "string" or type(Wanted) ~= "string" or Held == Wanted
end

local function Known(Record: Record, Op: Op, Format: Shape<any>): Prepared?
	for _, Existing in Record.Ops do
		if Existing.Id == Op.Id then
			if Existing.Tx == nil then
				return if Meant(Existing.TxTerms, Op.TxTerms) then VERDICT.Settled else VERDICT.Spent
			end
			return if Existing.TxGen == Op.TxGen then VERDICT.Prepared else VERDICT.Busy
		end
	end

	if type(Op.Tx) == "string" and type(Op.TxTerms) == "string" then
		local Recalled = Dedupe.Recall((Format:Fold(Detached(Record)) :: any)._Received, Dedupe.TX, Op.Tx, Op.TxTerms)
		if Recalled == Dedupe.OTHER then
			return VERDICT.Spent
		end
		if Recalled == Dedupe.SAME then
			return VERDICT.Settled
		end
	end

	for _, Id in Record.Seen do
		if Id == Op.Id then
			return VERDICT.Settled
		end
	end

	if type(Op.Tx) ~= "string" then
		return nil
	end

	if Dedupe.Has((Format:Fold(Detached(Record)) :: any)._Received, Dedupe.TX, Op.Tx) then
		return VERDICT.Settled
	end
	return nil
end

local function Fate(Op: Op, Verdict: Verdict): Fated?
	local Gen = Op.TxGen
	if type(Gen) ~= "string" or Gen == Verdict.Gen then
		return OWNED
	end

	if Verdict.Commit then
		return nil
	end

	local Since, At = Verdict.Since, Op.TxAt
	if Since ~= nil and type(At) == "number" and At < Since then
		return DEAD
	end
	return nil
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

local function Packed(Key: string, Record: Record, Format: Shape<any>): Record?
	if HasPending(Record) then
		return nil
	end

	local Snapshot = Fold(Format:Rehydrate(Record), Record.Ops, Format.Reducer)
	local Storable, Where = IsStorable.Structure(Snapshot)
	if not Storable then
		warn(`Ledger: key '{Key}' cannot be compacted, your reducer built state a datastore cannot hold, {Where}. the log is left alone rather than lose that field. no gaps in arrays, no mixing array and string keys, no nan`)
		return nil
	end

	local Seen = table.clone(Record.Seen)
	for _, Op in Record.Ops do
		table.insert(Seen, Op.Id)
	end
	local Keep = math.max(SEEN_LIMIT, #Record.Ops)
	local Overflow = #Seen - Keep
	if Overflow > 0 then
		Seen = table.move(Seen, Overflow + 1, #Seen, 1, {})
	end
	assert(#Seen >= #Record.Ops, "a compaction kept fewer applied ids than the ops it absorbed, so one could apply again")

	local Steps = Format.Migrations
	local Stored = Record.Version or 0
	local Ahead = Stored > #Steps

	local Packed: Record = {
		Envelope = ENVELOPE,
		Snapshot = Snapshot,
		Ops = {},
		Seen = Seen,
		Version = if Ahead then Stored else #Steps,
		Floor = if Ahead then Record.Floor or Stored else FloorOf(Steps)
	}

	Fault.Holds((Packed.Version :: number) >= Stored, `compacting '{Key}' moved it to an older version, so an older server could overwrite it`)
	Fault.Holds((Packed.Floor :: number) >= (Record.Floor or 0), `compacting '{Key}' lowered the version floor, so a server that cannot read it would think it can`)

	local Known: { [string]: boolean } = {}
	for _, Id in Seen do
		Known[Id] = true
	end
	for _, Op in Record.Ops do
		Fault.Holds(Known[Op.Id], `compacting '{Key}' absorbed op {Op.Id} without remembering it, so that op could apply a second time`)
	end

	return Packed
end

local Shape = {} :: Types.ShapeImpl<any>
Shape.__index = Shape

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
			error(Fault.New(Reasons.Behind, `the record needs format version {Floor} but this server only knows {#Steps} migrations, a newer server wrote it`))
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

	local Ready = Reconcile(self.Initial, Snapshot)
	for Field in self.Initial :: any do
		assert((Ready :: any)[Field] ~= nil, `loading dropped '{tostring(Field)}', which your Default declares, so the profile came back missing a field`)
	end
	return Ready
end

function Shape.Fold(self: Shape<any>, Record: Record): any
	return Fold(self:Rehydrate(Record), Record.Ops, self.Reducer)
end

function Shape.Certain(self: Shape<any>, Record: Record, Id: string): (boolean, boolean)
	local Base = self:Rehydrate(Record)
	local _, Took = Fold(Base, Record.Ops, self.Reducer, Id)

	local Pending: { [string]: boolean } = {}
	local Count = 0
	for _, Op in Record.Ops do
		if type(Op.Tx) == "string" and not Pending[Op.Tx] then
			Pending[Op.Tx] = true
			Count += 1
		end
	end
	if Count == 0 then
		return Took, true
	end
	if Count > 1 then
		return Took, false
	end

	local _, Also = Fold(Base, Landed(Record.Ops, next(Pending) :: string), self.Reducer, Id)
	return Took, Took == Also
end

local function NewShape<S>(Reducer: Types.Reducer<S>, Initial: S, Migrations: { Migration }?): Shape<S>
	return setmetatable({ Reducer = Reducer, Initial = Initial, Migrations = Migrations or {} }, Shape) :: any
end

table.freeze(Shape)

local Log = {} :: Types.LogImpl
Log.__index = Log

function Log.Update(self: Log, Key: string, Apply: Transform): Outcome
	local Before: Record = nil :: any
	local Wrote = false
	local Ok, Value = self.Wrapper:UpdateAsync(Key, function(Current: any): Record?
		Before = Materialize(Current)
		local Next = Apply(Before)
		Wrote = Next ~= nil
		return Next
	end)

	if not Ok then
		error(Value)
	end

	assert(Before ~= nil, `the write to '{Key}' reported success without ever running its transform`)
	assert(Wrote == (Value ~= nil), `the write to '{Key}' disagreed with the datastore about whether it happened`)

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
	local Added = 0
	local Before = 0

	local Owned = false
	for _, Op in Ops do
		assert(
			Op.Tx == nil,
			`op {Op.Id} carries a transaction stamp and is being appended to '{Key}' outside Prepare, so every fold would skip it`
		)
		if not IsStorable.Reserved(Op.Kind) then
			Owned = true
		end
	end

	local Outcome = self:Update(Key, function(Record: Record): Record?
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

		if Owned and Measure(Record.Ops) > MAX_LOG_BYTES then
			error(Fault.New(
				Reasons.Full,
				`'{Key}' is carrying {MAX_LOG_BYTES} bytes of ops that have not been compacted away, so this one cannot go on as well`
			))
		end

		Before, Added = Had, #Record.Ops - Had
		Record.Envelope = ENVELOPE
		Record.Erased = nil
		return Record
	end)

	if Outcome.Changed then
		Fault.Holds(Added > 0, `an append on '{Key}' rewrote the record without adding any of the ops it was given`)
		Fault.Holds(
			#Outcome.After.Ops == Before + Added,
			`the ops an append wrote to '{Key}' did not all come back, so the write was only partly stored`
		)
	end
	return Outcome.After
end

function Log.Entomb(self: Log, Key: string, At: number, Bury: ((Record) -> Record)?): Record
	return self:Update(Key, function(Record: Record): Record?
		local Body: Record = if Bury ~= nil then Bury(Record) else { Ops = {}, Seen = {} }
		Body.Ops = {}
		Body.Seen = {}
		Body.Envelope = ENVELOPE
		Body.Erased = At
		return Body
	end).Before
end

function Log.AppendUnlessPending(self: Log, Key: string, Ops: { Op }): Record
	return self:Append(Key, Ops, NotPending)
end

function Log.Prepare(self: Log, Key: string, Op: Op, Format: Shape<any>): Prepared
	assert(type(Op.Tx) == "string", "a transaction leg is being prepared without the transaction it belongs to")

	local Verdict = VERDICT.Rejected
	local Outcome = self:Update(Key, function(Record: Record): Record?
		local Already = Known(Record, Op, Format)
		if Already ~= nil then
			Verdict = Already
			return nil
		end

		if HasPending(Record) then
			Verdict = VERDICT.Busy
			return nil
		end

		local State = Format:Fold(Detached(Record))
		if Step(Format.Reducer, State, Unstamped(Op)) == nil then
			Verdict = VERDICT.Rejected
			return nil
		end

		table.insert(Record.Ops, Op)
		Record.Envelope = ENVELOPE
		Verdict = VERDICT.Prepared
		return Record
	end)

	if Verdict == VERDICT.Prepared then
		Fault.Holds(
			Holds(Outcome.After, Op.Id),
			`leg {Op.Id} reported as prepared but is not on '{Key}', so the transaction would wait on nothing`
		)
	end
	return Verdict
end

function Log.Resolve(self: Log, Key: string, Verdicts: { [string]: Verdict }): Resolution
	local Counts: { [string]: number } = {}
	local Result = self:Update(Key, function(Record: Record): Record?
		table.clear(Counts)
		local Kept: { Op } = {}
		local Retired = 0
		for _, Existing in Record.Ops do
			local Txid = Existing.Tx
			local Verdict = if type(Txid) == "string" then Verdicts[Txid] else nil
			local Fated = if Verdict ~= nil then Fate(Existing, Verdict) else nil
			if Fated == nil then
				table.insert(Kept, Existing)
				continue
			end
			if Fated == DEAD then
				Retired += 1
				continue
			end

			Counts[Txid] = (Counts[Txid] or 0) + 1
			if not (Verdict :: Verdict).Commit then
				continue
			end

			table.insert(Kept, Unstamped(Existing))
		end

		if next(Counts) == nil and Retired == 0 then
			return nil
		end

		assert(#Kept <= #Record.Ops, "resolving a transaction leg left more ops on the key than it started with")
		Record.Ops = Kept
		Record.Envelope = ENVELOPE
		return Record
	end)

	for Txid in Counts do
		for _, Op in Result.After.Ops do
			Fault.Holds(
				Op.Tx ~= Txid,
				`transaction '{Txid}' was resolved on '{Key}' but a leg is still stamped with it, so the key stays busy forever`
			)
		end
	end

	return { Record = Result.After, Counts = Counts }
end

function Log.Compact(self: Log, Key: string, Format: Shape<any>): Record
	local Result = self:Update(Key, function(Record: Record): Record?
		return Packed(Key, Record, Format)
	end)

	if not Result.Changed then
		return Result.After
	end

	assert(#Result.After.Ops == 0, `compacting '{Key}' left {#Result.After.Ops} op(s) behind`)

	local Bytes = Measure(Result.After)
	if Bytes > WARN_BYTES then
		warn(`Ledger: key '{Key}' is {Bytes} bytes and the datastore limit is {MAX_BYTES}. saves will start failing if it keeps growing{Hint(Result.After.Snapshot)}`)
	end
	return Result.After
end

function Log.Trim(self: Log, Key: string, Format: Shape<any>, Record: Record): Record
	if not Overgrown(Record) then
		return Record
	end

	local Ok, Packed = pcall(function(): Record
		return self:Compact(Key, Format)
	end)
	if Ok then
		return Packed
	end

	warn(`Ledger: could not compact '{Key}'. your write went through fine, the log just stays long: {Packed}`)
	return Record
end

local function NewLog(Wrapper: DataStoreWrapper): Log
	return setmetatable({ Wrapper = Wrapper }, Log) :: any
end

table.freeze(Log)

return table.freeze({
	New = NewLog,
	Shape = NewShape,
	Verdict = VERDICT,
	MAX_LOG_BYTES = MAX_LOG_BYTES,
	FloorOf = FloorOf,
	Migrate = Migrate,
	HasPending = HasPending,
	Detached = Detached,
	Landed = Landed,
	Holds = Holds,
	Known = Known,
	PendingTx = PendingTx,
	Oversized = Oversized,
	Overgrown = Overgrown
})
