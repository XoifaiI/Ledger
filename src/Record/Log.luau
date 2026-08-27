--!strict
--!optimize 2

--[=[
	Log: The record on one key.

	Read it, add ops to it, park a transaction leg on it, resolve one, bury it, or fold its log.
	Every write first asks whether this build may write the record.
	An append adds only the ops that the record does not have. An append that runs two times
	therefore applies one time.
	Materialize does not trust a field that it reads, because another build can write a record.
	A datastore hides an error that a transform throws. Update keeps that error and raises it again.

	Return type: A table with New, Verdict, TOMB_HORIZON, Entombed, NotEntombed and Known.
	Example usage:
		local Log = require("./Log")
		local Books = Log.New(Wrapper, 0)
		local Record = Books:Read("1")
--]=]

local Say = require("../Util/Tools/Say")
local DataStoreWrapper = require("../Util/Engine/DataStoreWrapper")
local Fault = require("../Contract/Fault")
local Limits = require("../Contract/Limits")
local Reasons = require("../Contract/Reason")
local Contract = require("../Contract/Op")
local Entries = require("../Contract/Entries")
local Measure = require("../Encode/Measure")
local IsStorable = require("../Encode/Storable")
local Transform = require("./Transform")
local Compact = require("./Compact")
local Shape = require("./Shape")
local Rules = require("./Rules")
local Stamp = require("./Stamp")
local Step = require("./Step")
local Types = require("./Types")

type Op = Contract.Op
type Record = Contract.Record<any>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper

type Allow = (Record) -> boolean
type Transform = (Record) -> Record?

export type Shape<S> = Types.Shape<S>
export type Log = Types.Log
export type Outcome = Types.Outcome
export type Resolution = Types.Resolution
export type Verdict = Types.Verdict
export type Prepared = Types.Prepared
export type Fated = Types.Fated

local ENVELOPE = Contract.ENVELOPE

local TOMB_HORIZON = Rules.TOMB_HORIZON

local OWNED = "Owned" :: "Owned"
local DEAD = "Dead" :: "Dead"

local VERDICT = table.freeze({
	Prepared = "Prepared" :: "Prepared",
	Settled = "Settled" :: "Settled",
	Busy = "Busy" :: "Busy",
	Rejected = "Rejected" :: "Rejected",
	Spent = "Spent" :: "Spent",
	Full = "Full" :: "Full",
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
	if type(Value.Bytes) ~= "number" or Value.Bytes < 0 then
		Value.Bytes = nil
	end
	if type(Value.Erased) ~= "number" then
		Value.Erased = nil
	end
	if type(Value.Floor) ~= "number" then
		Value.Floor = nil
	end

	return Value
end

local Entombed = Rules.Entombed

local function NotEntombed(Record: Record): boolean
	return not Entombed(Record)
end

local function Meant(Held: any, Wanted: any): boolean
	return type(Held) ~= "string" or type(Wanted) ~= "string" or Held == Wanted
end

local function Held(Record: Record, Format: Shape<any>, Hold: { any }): any
	local Folded = Hold[1]
	if Folded == nil then
		Folded = Format:Fold(Shape.Detached(Record))
		Hold[1] = Folded
	end
	return Folded
end

local function Known(Record: Record, Op: Op, Format: Shape<any>, Hold: { any }?): Prepared?
	local Folded: { any } = Hold or {}
	for _, Existing in Record.Ops do
		if Existing.Id == Op.Id then
			if Existing.Tx == nil then
				return if Meant(Existing.TxTerms, Op.TxTerms) then VERDICT.Settled else VERDICT.Spent
			end
			return if Existing.TxGen == Op.TxGen then VERDICT.Prepared else VERDICT.Busy
		end
	end

	if type(Op.Tx) == "string" and type(Op.TxTerms) == "string" then
		local Recalled = Entries.Recall(Held(Record, Format, Folded)._Received, Entries.TX, Op.Tx, Op.TxTerms)
		if Recalled == Entries.OTHER then
			return VERDICT.Spent
		end
		if Recalled == Entries.SAME then
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

	if Entries.Has(Held(Record, Format, Folded)._Received, Entries.TX, Op.Tx) then
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

local Log = {} :: Types.LogImpl
Log.__index = Log

function Log.New(Wrapper: DataStoreWrapper, Known: number?, Floor: number?): Log
	return setmetatable({ Wrapper = Wrapper, Known = Known, Floor = Floor }, Log) :: any
end

function Log.Legible(self: Log, Key: string, Record: Record)
	Rules.Readable(Key, self.Known, Record)
end

function Log.Update(self: Log, Key: string, Apply: Transform): Outcome
	local Before: Record = nil :: any
	local Wrote = false
	local Raised: any = nil

	local Ok, Value = self.Wrapper:UpdateAsync(Key, function(Current: any): Record?
		Wrote = false
		Raised = nil

		local Fine, Next = pcall(function(): Record?
			Before = Materialize(Current)
			return Apply(Before)
		end)
		if not Fine then
			Raised = Next
			return nil
		end

		Wrote = Next ~= nil
		return Next
	end)

	if Raised ~= nil then
		error(Raised, 0)
	end
	if not Ok then
		error(Value)
	end

	Fault.Holds(Before ~= nil, `the write to '{Key}' reported success without ever running its transform`)
	Fault.Holds(Wrote == (Value ~= nil), `the write to '{Key}' disagreed with the datastore about whether it happened`)

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

function Log.Append(self: Log, Key: string, Ops: { Op }, Guard: Allow?, Sift: Rules.Sift?): (Record, { string })
	local Owned = false
	for _, Op in Ops do
		Fault.Holds(Op.Tx == nil, `op {Op.Id} carries a transaction stamp and is being appended to '{Key}' outside Prepare, so every fold would skip it`)
		if not IsStorable.Reserved(Op.Kind) then
			Owned = true
		end
	end

	local Outcome = Transform.Run(
		function(Named: string, Apply: (Record) -> Record?)
			return self:Update(Named, Apply)
		end,
		Key,
		{
			Rules.Legible(Key, self.Known),
			Rules.Allowed(Guard),
			Rules.Fresh(Ops, Sift),
			Rules.Capped(Key, Owned),
			Rules.Format(self.Floor),
			Rules.Tomb(Key, Owned),
		}
	)

	local Turned = Outcome.Notes.Turned
	return Outcome.After, if type(Turned) == "table" then Turned else {}
end

function Log.Entomb(self: Log, Key: string, At: number, Bury: ((Record) -> Record)?): Record
	return self:Update(Key, function(Record: Record): Record?
		self:Legible(Key, Record)
		if Stamp.HasPending(Record) then
			error(Fault.New(Reasons.Busy, `'{Key}' has a transaction parked on it, so erasing it now would drop a leg the transaction still counts as committed`))
		end

		local Body: Record = if Bury ~= nil then Bury(Record) else { Ops = {}, Seen = {} }
		Body.Ops = {}
		Body.Seen = {}
		Body.Envelope = ENVELOPE
		Body.Erased = At
		return Body
	end).Before
end

function Log.AppendUnlessPending(self: Log, Key: string, Ops: { Op }): Record
	return (self:Append(Key, Ops, Stamp.NotPending))
end

function Log.Prepare(self: Log, Key: string, Op: Op, Format: Shape<any>): Prepared
	Fault.Holds(type(Op.Tx) == "string", "a transaction leg is being prepared without the transaction it belongs to")

	local Verdict: Prepared = VERDICT.Rejected
	local Outcome = self:Update(Key, function(Record: Record): Record?
		Verdict = VERDICT.Rejected
		local Folded: { any } = {}
		self:Legible(Key, Record)
		local Already = Known(Record, Op, Format, Folded)
		if Already ~= nil then
			Verdict = Already
			return nil
		end

		if Stamp.HasPending(Record) then
			Verdict = VERDICT.Busy
			return nil
		end

		local State = Held(Record, Format, Folded)
		local Next = Step(Format.Reducer, State, Stamp.Unstamped(Op))
		if Next == nil then
			Verdict = VERDICT.Rejected
			return nil
		end

		local LogBytes = Measure(Record.Ops)
		local OpBytes = Measure(Op)
		if Compact.Bulk(Record) + LogBytes + OpBytes > Limits.StateFloor then
			local Bytes = Measure(Next)
			if Bytes > Limits.State and Bytes > Measure(State) then
				Verdict = VERDICT.Full
				return nil
			end
		end

		local Separator = if #Record.Ops > 0 then 1 else 0
		table.insert(Record.Ops, Op)
		if LogBytes + OpBytes + Separator > Limits.Log then
			Verdict = VERDICT.Full
			return nil
		end

		Record.Envelope = ENVELOPE
		if type(self.Floor) == "number" and self.Floor > (Record.Floor or 0) then
			Record.Floor = self.Floor
		end
		Verdict = VERDICT.Prepared
		return Record
	end)

	if Verdict == VERDICT.Prepared then
		Fault.Holds(Stamp.Holds(Outcome.After, Op.Id), `leg {Op.Id} reported as prepared but is not on '{Key}', so the transaction would wait on nothing`)
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
			if type(Txid) ~= "string" then
				table.insert(Kept, Existing)
				continue
			end

			local Verdict = Verdicts[Txid]
			if Verdict == nil then
				table.insert(Kept, Existing)
				continue
			end

			local Fated = Fate(Existing, Verdict)
			if Fated == nil then
				table.insert(Kept, Existing)
				continue
			end
			if Fated == DEAD then
				Retired += 1
				continue
			end

			Counts[Txid] = (Counts[Txid] or 0) + 1
			if not Verdict.Commit then
				continue
			end

			table.insert(Kept, Stamp.Unstamped(Existing))
		end

		if next(Counts) == nil and Retired == 0 then
			return nil
		end

		Fault.Holds(#Kept <= #Record.Ops, "resolving a transaction leg left more ops on the key than it started with")
		Record.Ops = Kept
		Record.Envelope = ENVELOPE
		return Record
	end)

	for Txid in Counts do
		for _, Op in Result.After.Ops do
			Fault.Holds(Op.Tx ~= Txid, `transaction '{Txid}' was resolved on '{Key}' but a leg is still stamped with it, so the key stays busy forever`)
		end
	end

	return { Record = Result.After, Counts = Counts }
end

function Log.Compact(self: Log, Key: string, Format: Shape<any>): Record
	local Result = self:Update(Key, function(Record: Record): Record?
		self:Legible(Key, Record)
		return Compact.Packed(Key, Record, Format)
	end)

	if not Result.Changed then
		return Result.After
	end

	Fault.Holds(
		#Result.After.Ops == 0 or #Result.After.Ops < #Result.Before.Ops,
		`compacting '{Key}' left {#Result.After.Ops} op(s) behind, which is no fewer than the {#Result.Before.Ops} it started with`
	)

	local Bytes = Measure(Result.After)
	if Bytes > Limits.ValueWarn then
		Say.Warn(`Ledger: key '{Key}' is {Bytes} bytes and the datastore limit is {Limits.Value}. saves will start failing if it keeps growing{Compact.Hint(Result.After.Snapshot)}`)
	end

	local State = Result.After.Bytes
	if type(State) == "number" and State > Limits.StateWarn then
		local Said, Ours = Compact.Hint(Result.After.Snapshot)
		local Fix = if Ours
			then "that field is Ledger's own bookkeeping and your game cannot take it out. it grows with the transfers, transactions and reservations this key takes, so spread that work over more keys"
			else "take out what the game no longer reads, or spread it over more keys"
		Say.Warn(`Ledger: the state on key '{Key}' is {State} bytes and Ledger stops taking writes at {Limits.State}{Said}. {Fix}`)
	end
	return Result.After
end

function Log.Trim(self: Log, Key: string, Format: Shape<any>, Record: Record): Record
	if not Compact.Overgrown(Record) then
		return Record
	end

	local Ok, Packed = pcall(self.Compact, self, Key, Format)
	if Ok then
		return Packed
	end

	Say.Warn(`Ledger: could not compact '{Key}'. your write went through fine, the log just stays long: {Packed}`)
	return Record
end

table.freeze(Log)

return table.freeze({
	New = Log.New,
	Verdict = VERDICT,
	TOMB_HORIZON = TOMB_HORIZON,
	Entombed = Entombed,
	NotEntombed = NotEntombed,
	Known = Known,
})
