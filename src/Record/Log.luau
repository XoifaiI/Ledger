--!strict
--!optimize 2

--[=[

	Log: The record on one key.

	Read it, add ops to it, park a transaction leg on it, resolve one, bury it, compact it or trim it.
	An append adds only the ops the record does not already have, so running one twice applies once.
	Every write first asks whether this build may write the record at all.

	Return type: A table with New, Verdict, Entombed and NotEntombed.
	Example usage:
		local Log = require("./Log")
		local Books = Log.New(Wrapper, 0)
		local Record = Books:Read("1")
--]=]

local DataStoreWrapper = require("../Util/DataStoreWrapper")
local MemoryStoreWrapper = require("../Util/MemoryStoreWrapper")
local Windows = require("../Core/Constants/Windows")
local Sizes = require("../Core/Constants/Sizes")
local Errors = require("../Core/Errors")
local Reasons = require("../Core/Constants/Reasons")
local Verdicts = require("../Core/Constants/Verdicts")
local Kinds = require("../Core/Constants/Kinds")
local Shapes = require("../Core/Shapes")
local Tags = require("../Core/Constants/Tags")
local Applied = require("../Core/Applied")
local Mark = require("../Encode/Mark")
local Measure = require("../Encode/Measure")
local Storable = require("../Encode/Storable")
local Transform = require("./Transform")
local Compact = require("./Compact")
local Schema = require("./Schema")
local Rules = require("./Rules")
local TxStamp = require("./TxStamp")
local Apply = require("./Apply")
local Types = require("./Types")

type Op = Shapes.Op
type Record = Shapes.Record<any>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type MemoryStoreWrapper = MemoryStoreWrapper.MemoryStoreWrapper

type Allow = (Record) -> boolean
type Transform = (Record) -> Record?

export type Schema<S> = Types.Shape<S>
export type Log = Types.Log
export type Outcome = Types.Outcome
export type Resolution = Types.Resolution
export type Verdict = Types.Verdict
export type Prepared = Types.Prepared
export type Fated = Types.Fated

local function Materialize(Value: any): Record
	if type(Value) ~= "table" then
		return { Ops = {}, Seen = {} }
	end

	if type(Value.Envelope) == "number" and Value.Envelope > Kinds.ENVELOPE then
		Errors.Raise(Reasons.Behind, `a newer Ledger than this server runs wrote this record, so this server cannot read it. finish the deploy`)
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

local function Flagged(Value: any): string?
	if type(Value) ~= "table" or type(Value.Version) ~= "string" then
		return nil
	end
	return Value.Version
end

local function Meant(Held: any, Wanted: any): boolean
	return type(Held) ~= "string" or type(Wanted) ~= "string" or Held == Wanted
end

local function Held(Record: Record, Format: Schema<any>, Hold: { any }): any
	local Folded = Hold[1]
	if Folded == nil then
		Folded = Format:Fold(Schema.Detached(Record))
		Hold[1] = Folded
	end
	return Folded
end

local function Known(Record: Record, Op: Op, Format: Schema<any>, Hold: { any }?): Prepared?
	local Folded: { any } = Hold or {}
	for _, Existing in Record.Ops do
		if Existing.Id == Op.Id then
			if Existing.Tx == nil then
				return if Meant(Existing.TxTerms, Op.TxTerms) then Verdicts.SETTLED else Verdicts.SPENT
			end
			return if Existing.TxGen == Op.TxGen then Verdicts.PREPARED else Verdicts.BUSY
		end
	end

	if type(Op.Tx) == "string" and type(Op.TxTerms) == "string" then
		local Recalled = Applied.Recall(Held(Record, Format, Folded)._Received, Tags.TX, Op.Tx, Op.TxTerms)
		if Recalled == Tags.OTHER then
			return Verdicts.SPENT
		end
		if Recalled == Tags.SAME then
			return Verdicts.SETTLED
		end
	end

	for _, Id in Record.Seen do
		if Id == Op.Id then
			return Verdicts.SETTLED
		end
	end

	if type(Op.Tx) ~= "string" then
		return nil
	end

	if Applied.Has(Held(Record, Format, Folded)._Received, Tags.TX, Op.Tx) then
		return Verdicts.SETTLED
	end
	return nil
end

local function Fate(Op: Op, Verdict: Verdict): Fated?
	local Gen = Op.TxGen
	if type(Gen) ~= "string" or Gen == Verdict.Gen then
		return Verdicts.OWNED
	end

	if Verdict.Commit then
		return nil
	end

	local Since, At = Verdict.Since, Op.TxAt
	if Since ~= nil and type(At) == "number" and At < Since then
		return Verdicts.DEAD
	end
	return nil
end

local Log = {} :: Types.LogImpl
Log.__index = Log

function Log.New(Wrapper: DataStoreWrapper, Known: number?, Floor: number?, Flags: MemoryStoreWrapper?): Log
	return setmetatable({ Wrapper = Wrapper, Known = Known, Floor = Floor, Flags = Flags }, Log) :: any
end

function Log.Legible(self: Log, Key: string, Record: Record)
	Rules.Readable(Key, self.Known, Record)
end

function Log.Flag(self: Log, Key: string, Info: DataStoreKeyInfo?)
	local Flags = self.Flags
	if Flags == nil or Info == nil then
		return
	end

	local Revision, At = Info.Version, Info.UpdatedTime
	if type(Revision) ~= "string" or type(At) ~= "number" then
		return
	end

	local Slot = Mark.Cached({ self.Wrapper.Name, Key })
	self.Wrapper.Scheduler.Spawn(function()
		Flags:UpdateAsync(Slot, function(Current: any): any
			if type(Current) == "table" and type(Current.At) == "number" and Current.At > At then
				return nil
			end
			return { Version = Revision, At = At }
		end, Windows.IDLE_FLAG)
	end)
end

function Log.Update(self: Log, Key: string, Change: Transform): Outcome
	local Before: Record = nil :: any
	local Wrote = false
	local Raised: any = nil

	local Ok, Value, Info = self.Wrapper:UpdateAsync(Key, function(Current: any): Record?
		Wrote = false
		Raised = nil

		local Fine, Next = pcall(function(): Record?
			Before = Materialize(Current)
			return Change(Before)
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

	assert(Before ~= nil, `the write to '{Key}' reported success without ever running its transform`)
	assert(Wrote == (Value ~= nil), `the write to '{Key}' disagreed with the datastore about whether it happened`)

	if Value == nil then
		return { Before = Before, After = Before, Changed = false }
	end

	local Revision = if Info ~= nil then (Info :: DataStoreKeyInfo).Version else nil
	self:Flag(Key, Info)
	return { Before = Before, After = Materialize(Value), Changed = true, Revision = Revision }
end

function Log.Read(self: Log, Key: string): (Record, string?)
	local Ok, Value, Info = self.Wrapper:GetAsync(Key)
	if not Ok then
		error(Value)
	end
	return Materialize(Value), if Info ~= nil then (Info :: DataStoreKeyInfo).Version else nil
end

function Log.ReadVersion(self: Log, Key: string, Version: string): Record
	local Ok, Value = self.Wrapper:GetVersionAsync(Key, Version)
	if not Ok then
		error(Value)
	end
	return Materialize(Value)
end

function Log.Append(self: Log, Key: string, Ops: { Op }, Guard: Allow?, Sift: Rules.Sift?): (Record, { string }, { string }, string?)
	local Owned = false
	for _, Op in Ops do
		assert(Op.Tx == nil, `op {Op.Id} carries a transaction stamp and is being appended to '{Key}' outside Prepare, so every fold would skip it`)
		if not Storable.Reserved(Op.Kind) then
			Owned = true
		end
	end

	local Outcome = Transform.Run(
		function(Named: string, Change: (Record) -> Record?)
			return self:Update(Named, Change)
		end,
		Key,
		{
			Rules.Legible(Key, self.Known),
			Rules.Allowed(Guard),
			Rules.Fresh(Ops, Sift),
			Rules.Capped(Key, Owned),
			Rules.Format(self.Floor),
			Rules.Tomb(),
		}
	)

	local Turned, Waiting = Outcome.Notes.Turned, Outcome.Notes.Waiting
	return Outcome.After, if type(Turned) == "table" then Turned else {}, if type(Waiting) == "table" then Waiting else {}, Outcome.Revision
end

function Log.Entomb(self: Log, Key: string, At: number, Bury: ((Record) -> Record)?): Record
	return self:Update(Key, function(Record: Record): Record?
		self:Legible(Key, Record)
		if TxStamp.HasPending(Record) then
			Errors.Raise(Reasons.Busy, `'{Key}' has a transaction parked on it, so it cannot be erased yet. wait for that to settle`)
		end

		local Body: Record = if Bury ~= nil then Bury(Record) else { Ops = {}, Seen = {} }
		Body.Ops = {}
		Body.Seen = {}
		Body.Envelope = Kinds.ENVELOPE
		Body.Erased = At
		return Body
	end).Before
end

function Log.AppendUnlessPending(self: Log, Key: string, Ops: { Op }): Record
	return (self:Append(Key, Ops, TxStamp.NotPending))
end

function Log.Prepare(self: Log, Key: string, Op: Op, Format: Schema<any>): Prepared
	assert(type(Op.Tx) == "string", "a transaction leg is being prepared without the transaction it belongs to")

	local Verdict: Prepared = Verdicts.REJECTED
	local Outcome = self:Update(Key, function(Record: Record): Record?
		Verdict = Verdicts.REJECTED
		local Folded: { any } = {}
		self:Legible(Key, Record)
		local Already = Known(Record, Op, Format, Folded)
		if Already ~= nil then
			Verdict = Already
			return nil
		end

		if Entombed(Record) then
			Verdict = Verdicts.ERASED
			return nil
		end

		if TxStamp.HasPending(Record) then
			Verdict = Verdicts.BUSY
			return nil
		end

		local State = Held(Record, Format, Folded)
		local Next = Apply(Format.Reducer, State, TxStamp.Unstamped(Op))
		if Next == nil then
			Verdict = Verdicts.REJECTED
			return nil
		end

		local LogBytes = Measure(Record.Ops)
		local OpBytes = Measure(Op)
		if Compact.Bulk(Record) + LogBytes + OpBytes > Sizes.StateFloor then
			local Bytes = Measure(Next)
			if Bytes > Sizes.State and Bytes > Measure(State) then
				Verdict = Verdicts.FULL
				return nil
			end
		end

		local Separator = if #Record.Ops > 0 then 1 else 0
		table.insert(Record.Ops, Op)
		if LogBytes + OpBytes + Separator > Sizes.Log then
			Verdict = Verdicts.FULL
			return nil
		end

		Record.Envelope = Kinds.ENVELOPE
		if type(self.Floor) == "number" and self.Floor > (Record.Floor or 0) then
			Record.Floor = self.Floor
		end
		Verdict = Verdicts.PREPARED
		return Record
	end)

	if Verdict == Verdicts.PREPARED then
		assert(TxStamp.Holds(Outcome.After, Op.Id), `leg {Op.Id} reported as prepared but is not on '{Key}', so the transaction would wait on nothing`)
	end
	return Verdict
end

function Log.Resolve(self: Log, Key: string, Rulings: { [string]: Verdict }): Resolution
	local Counts: { [string]: number } = {}
	local Result = self:Update(Key, function(Record: Record): Record?
		table.clear(Counts)
		self:Legible(Key, Record)

		local Kept: { Op } = {}
		local Retired = 0
		for _, Existing in Record.Ops do
			local Txid = Existing.Tx
			if type(Txid) ~= "string" then
				table.insert(Kept, Existing)
				continue
			end

			local Verdict = Rulings[Txid]
			if Verdict == nil then
				table.insert(Kept, Existing)
				continue
			end

			local Fated = Fate(Existing, Verdict)
			if Fated == nil then
				table.insert(Kept, Existing)
				continue
			end
			if Fated == Verdicts.DEAD then
				Retired += 1
				continue
			end

			Counts[Txid] = (Counts[Txid] or 0) + 1
			if not Verdict.Commit then
				continue
			end

			table.insert(Kept, TxStamp.Unstamped(Existing))
		end

		if next(Counts) == nil and Retired == 0 then
			return nil
		end

		assert(#Kept <= #Record.Ops, "resolving a transaction leg left more ops on the key than it started with")
		Record.Ops = Kept
		Record.Envelope = Kinds.ENVELOPE
		return Record
	end)

	for Txid in Counts do
		for _, Op in Result.After.Ops do
			assert(Op.Tx ~= Txid, `transaction '{Txid}' was resolved on '{Key}' but a leg is still stamped with it, so the key stays busy forever`)
		end
	end

	return { Record = Result.After, Counts = Counts }
end

function Log.Compact(self: Log, Key: string, Format: Schema<any>): (Record, string?)
	local Result = self:Update(Key, function(Record: Record): Record?
		self:Legible(Key, Record)
		return Compact.Packed(Key, Record, Format)
	end)

	if not Result.Changed then
		return Result.After, nil
	end

	assert(
		#Result.After.Ops == 0 or #Result.After.Ops < #Result.Before.Ops,
		`compacting '{Key}' left {#Result.After.Ops} op(s) behind, which is no fewer than the {#Result.Before.Ops} it started with`
	)

	local Bytes = Measure(Result.After)
	if Bytes > Sizes.ValueWarn then
		warn(`Ledger: key '{Key}' is {Bytes} bytes and the datastore limit is {Sizes.Value}. saves will start failing if it keeps growing{Compact.Hint(Result.After.Snapshot)}`)
	end

	local State = Result.After.Bytes
	if type(State) == "number" and State > Sizes.StateWarn then
		local Said, Ours = Compact.Hint(Result.After.Snapshot)
		local Fix = if Ours
			then "that field is Ledger's own bookkeeping and your game cannot take it out. it grows with the transfers, transactions and reservations this key takes, so spread that work over more keys"
			else "take out what the game no longer reads, or spread it over more keys"
		warn(`Ledger: the state on key '{Key}' is {State} bytes and Ledger stops taking writes at {Sizes.State}{Said}. {Fix}`)
	end
	return Result.After, Result.Revision
end

function Log.Trim(self: Log, Key: string, Format: Schema<any>, Record: Record): Record
	if not Compact.Overgrown(Record) then
		return Record
	end

	local Ok, Packed = pcall(function(): Record
		return (self:Compact(Key, Format))
	end)
	if Ok then
		return Packed
	end

	warn(`Ledger: could not compact '{Key}'. your write went through fine, the log just stays long: {Packed}`)
	return Record
end

table.freeze(Log)

return table.freeze({
	New = Log.New,
	Entombed = Entombed,
	NotEntombed = NotEntombed,
	Flagged = Flagged,
})
