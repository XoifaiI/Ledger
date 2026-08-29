--!strict
--!optimize 2

--[=[
	Compact: Folds the ops on a key into a new snapshot.

	A large profile costs a lot to write again, so Compact waits until the log is a share of it. A
	small profile is cheap, so Compact folds it on a count.
	Hint names the field taking the most room, and whether that field is Ledger's own.
	Compact absorbs only the ops at the front that this build can apply. The first op that this build
	cannot apply stops the walk, and each op after it waits for a build that can.
	Compact holds back an op that the reducer refuses. It does not drop the op. The exception is an op
	this build took in only because a transaction was parked, since a compaction runs on a settled
	record and that op can never apply now.

	Return type: A table with Packed, Worthwhile, Oversized, Overgrown, Bulk, Hint and SEEN_LIMIT.
	Example usage:
		local Compact = require("./Compact")
		if Compact.Overgrown(Record) then Fold() end
--]=]

local Warnings = require("../Util/Warnings")
local TableUtil = require("../Util/TableUtil")
local Sizes = require("../Core/Constants/Sizes")
local Measure = require("../Encode/Measure")
local Storable = require("../Encode/Storable")
local Errors = require("../Core/Errors")
local Shapes = require("../Core/Shapes")
local Applied = require("../Core/Applied")
local Schema = require("./Schema")
local TxStamp = require("./TxStamp")
local Apply = require("./Apply")
local Types = require("./Types")

type Op = Shapes.Op
type Record = Shapes.Record<any>
type Schema<S> = Types.Shape<S>

local SEEN_LIMIT = 2048

local COMPACT_OPS = 128
local COMPACT_CEILING = 512
local COMPACT_SHARE = 0.2

local function Worthwhile(Ops: number, Bytes: number, State: number): boolean
	if Ops >= COMPACT_CEILING or Bytes >= Sizes.Compact then
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
		return Bytes >= Sizes.Compact
	end

	return Worthwhile(Count, Bytes, Bulk(Record))
end

local function Accounted(State: any, Op: Op, Format: Schema<any>): boolean
	local Handles = Format.Handles
	if if Handles ~= nil then Handles[Op.Kind] == true else Storable.Reserved(Op.Kind) then
		return true
	end

	if Op.TxOnly == true then
		return true
	end

	local Data: any = State
	if type(Op.Once) == "string" and Applied.Has(Data._Received, Applied.ONCE, Op.Once) then
		return true
	end
	return type(Op.TxSticky) == "string" and Applied.Has(Data._Received, Applied.TX, Op.TxSticky)
end

local function Absorbable(Record: Record, Format: Schema<any>): (any, number, string?)
	local FreezeDelta = TableUtil.FreezeDelta
	local Reducer = Format.Reducer
	local State = FreezeDelta(Format:Rehydrate(Record))
	local Taken = 0

	for _, Op in Record.Ops do
		local Next = Apply(Reducer, State, Op)
		if Next ~= nil then
			State = FreezeDelta(Next)
			Taken += 1
			continue
		end
		if Accounted(State, Op, Format) then
			Taken += 1
			continue
		end
		return State, Taken, Op.Kind
	end

	return State, Taken, nil
end

local function Hint(Snapshot: any): (string, boolean)
	if type(Snapshot) ~= "table" then
		return "", false
	end

	local Name, Best = nil :: any, 0
	for Key, Value in Snapshot do
		local Size = Measure(Value)
		if Size > Best then
			Name, Best = Key, Size
		end
	end

	if Name == nil then
		return "", false
	end
	return ` (largest field '{tostring(Name)}' at {Best} bytes)`, Storable.Bookkeeping(tostring(Name))
end

local function Packed(Key: string, Record: Record, Format: Schema<any>): Record?
	if TxStamp.HasPending(Record) then
		return nil
	end

	local Snapshot, Taken, Blocking = Absorbable(Record, Format)
	if Taken == 0 and #Record.Ops > 0 then
		Warnings.Warn(`Ledger: key '{Key}' cannot be compacted, its oldest op is a '{Blocking}' this build does not apply. a build that does apply it compacts the key`)
		return nil
	end

	local Fits, Where = Storable.Structure(Snapshot)
	if not Fits then
		Warnings.Warn(
			`Ledger: key '{Key}' cannot be compacted, your reducer built state a datastore cannot hold, {Where}. the log is left alone rather than lose that field. no gaps in arrays, no mixing array and string keys, no nan`
		)
		return nil
	end

	local Held: { Op } = table.move(Record.Ops, Taken + 1, #Record.Ops, 1, {})
	if Blocking ~= nil then
		Warnings.Warn(`Ledger: key '{Key}' kept {#Held} op(s) through compaction, from a '{Blocking}' this build does not apply. they wait for a build that does rather than being dropped`)
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

	local Steps = Format.Migrations
	local Stored = Record.Version or 0
	local Ahead = Stored > #Steps

	local Fresh: Record = {
		Envelope = Shapes.ENVELOPE,
		Snapshot = Snapshot,
		Bytes = Measure(Snapshot),
		Ops = Held,
		Seen = Seen,
		Erased = Record.Erased,
		Version = if Ahead then Stored else #Steps,
		Floor = if Ahead then Record.Floor or Stored else Schema.FloorOf(Steps),
	}

	Errors.Holds((Fresh.Floor :: number) >= (Record.Floor or 0), `compacting '{Key}' lowered the version floor, so a server that cannot read it would think it can`)

	return Fresh
end

return table.freeze({
	Packed = Packed,
	Worthwhile = Worthwhile,
	Oversized = Oversized,
	Overgrown = Overgrown,
	Bulk = Bulk,
	Hint = Hint,
	SEEN_LIMIT = SEEN_LIMIT,
})
