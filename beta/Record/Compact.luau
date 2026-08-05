--!strict
--!optimize 2

--[=[
	Compact: Folds the ops on a key into a new snapshot.
	
	A large profile costs a lot to write again, so it waits until the log is a share of it.
	A small profile is cheap, so it folds on a count.
	Only the ops at the front that this build can apply are absorbed. The first op that this build
	cannot apply stops the walk, and each op after it stays for a build that can apply it.
	An op that the reducer refuses is held back and not dropped, even when this build knows its kind.
	A later build may read it another way, and to absorb it would answer for that build.
	
	Return type: A table with Packed, Worthwhile, Oversized, Overgrown, Bulk, Hint and SEEN_LIMIT.
	Example usage:
		local Compact = require("./Compact")
		if Compact.Overgrown(Record) then Fold() end
--]=]

local TableUtil = require("../Util/TableUtil")
local Measure = require("../Encode/Measure")
local IsStorable = require("../Encode/Storable")
local Fault = require("../Contract/Fault")
local Contract = require("../Contract/Op")
local Entries = require("../Kernel/Entries")
local Shape = require("./Shape")
local Stamp = require("./Stamp")
local Step = require("./Step")
local Types = require("./Types")

type Op = Contract.Op
type Record = Contract.Record<any>
type Shape<S> = Types.Shape<S>

local SEEN_LIMIT = 2048

local COMPACT_OPS = 128
local COMPACT_CEILING = 512
local COMPACT_SHARE = 0.2
local COMPACT_BYTES = 1024 * 1024

local function Worthwhile(Ops: number, Bytes: number, State: number): boolean
	if Ops >= COMPACT_CEILING or Bytes >= COMPACT_BYTES then
		return true
	end
	if Ops < COMPACT_OPS then
		return false
	end
	return Bytes >= State * COMPACT_SHARE
end

local function Oversized(Ops: number, Bytes: number, State: number?): boolean
	return Worthwhile(Ops, Bytes, State or 0)
end

local function Bulk(Record: Record): number
	if type(Record.Bytes) == "number" then
		return Record.Bytes
	end
	return Measure(Record.Snapshot)
end

local function Overgrown(Record: Record): boolean
	local Count = #Record.Ops
	local Bytes = Measure(Record.Ops)
	if Count < COMPACT_OPS then
		return Bytes >= COMPACT_BYTES
	end

	return Worthwhile(Count, Bytes, Bulk(Record))
end

local function Accounted(State: any, Op: Op): boolean
	if IsStorable.Reserved(Op.Kind) then
		return true
	end

	local Data: any = State
	if type(Op.Once) == "string" and Entries.Has(Data._Received, Entries.ONCE, Op.Once) then
		return true
	end
	return type(Op.TxSticky) == "string" and Entries.Has(Data._Received, Entries.TX, Op.TxSticky)
end

local function Absorbable(Record: Record, Format: Shape<any>): (any, number, string?)
	local State = TableUtil.FreezeDelta(Format:Rehydrate(Record))
	local Taken = 0

	for _, Op in Record.Ops do
		local Next = Step(Format.Reducer, State, Op)
		if Next ~= nil then
			State = TableUtil.FreezeDelta(Next)
			Taken += 1
			continue
		end
		if Accounted(State, Op) then
			Taken += 1
			continue
		end
		return State, Taken, Op.Kind
	end

	return State, Taken, nil
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

local function Packed(Key: string, Record: Record, Format: Shape<any>): Record?
	if Stamp.HasPending(Record) then
		return nil
	end

	local Snapshot, Taken, Blocking = Absorbable(Record, Format)
	if Taken == 0 and #Record.Ops > 0 then
		warn(`Ledger: key '{Key}' cannot be compacted, its oldest op is a '{Blocking}' this build does not apply. a build that does apply it compacts the key`)
		return nil
	end

	local Storable, Where = IsStorable.Structure(Snapshot)
	if not Storable then
		warn(`Ledger: key '{Key}' cannot be compacted, your reducer built state a datastore cannot hold, {Where}. the log is left alone rather than lose that field. no gaps in arrays, no mixing array and string keys, no nan`)
		return nil
	end

	local Held: { Op } = table.move(Record.Ops, Taken + 1, #Record.Ops, 1, {})
	if Blocking ~= nil then
		warn(`Ledger: key '{Key}' kept {#Held} op(s) through compaction, from a '{Blocking}' this build does not apply. they wait for a build that does rather than being dropped`)
	end

	local Seen = table.clone(Record.Seen)
	for Index = 1, Taken do
		table.insert(Seen, Record.Ops[Index].Id)
	end
	local Keep = math.max(SEEN_LIMIT, Taken)
	local Overflow = #Seen - Keep
	if Overflow > 0 then
		Seen = table.move(Seen, Overflow + 1, #Seen, 1, {})
	end
	Fault.Holds(#Seen >= Taken, "a compaction kept fewer applied ids than the ops it absorbed, so one could apply again")

	local Steps = Format.Migrations
	local Stored = Record.Version or 0
	local Ahead = Stored > #Steps

	local Fresh: Record = {
		Envelope = Contract.ENVELOPE,
		Snapshot = Snapshot,
		Bytes = Measure(Snapshot),
		Ops = Held,
		Seen = Seen,
		Erased = Record.Erased,
		Version = if Ahead then Stored else #Steps,
		Floor = if Ahead then Record.Floor or Stored else Shape.FloorOf(Steps)
	}

	Fault.Holds((Fresh.Version :: number) >= Stored, `compacting '{Key}' moved it to an older version, so an older server could overwrite it`)
	Fault.Holds((Fresh.Floor :: number) >= (Record.Floor or 0), `compacting '{Key}' lowered the version floor, so a server that cannot read it would think it can`)

	local Remembered: { [string]: boolean } = {}
	for _, Id in Seen do
		Remembered[Id] = true
	end
	for Index = 1, Taken do
		local Op = Record.Ops[Index]
		Fault.Holds(Remembered[Op.Id], `compacting '{Key}' absorbed op {Op.Id} without remembering it, so that op could apply a second time`)
	end

	return Fresh
end

return table.freeze({
	Packed = Packed,
	Worthwhile = Worthwhile,
	Oversized = Oversized,
	Overgrown = Overgrown,
	Bulk = Bulk,
	Hint = Hint,
	SEEN_LIMIT = SEEN_LIMIT
})
