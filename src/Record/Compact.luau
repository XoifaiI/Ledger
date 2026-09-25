--!strict
--!optimize 2

--[=[

	Compact: Folds the ops on a key into a new snapshot.

	Overgrown and Oversized say whether a key is worth compacting. They read a share of the snapshot
	for a large state and a count for a small one. Packed does the fold. It absorbs the run of ops at
	the front this build can apply, keeps the rest, and moves the absorbed ids to Seen. Seen keeps a
	fixed count, so each compaction notes how many ids it absorbed and when. Dropping the oldest ids
	moves the horizon to the newest time among them. An id no run covers came from before the runs
	and moves nothing. The runs are capped, and merging two keeps the later time.

	An op taken in only because a transaction was parked names those transactions. Packed absorbs it
	only while none of them has left its name on the key. A transaction that committed leaves an
	ordinary op, and a build that cannot apply that op has to hold it. A Ledger op the fold refuses
	is absorbed only when the state knows the field it names. A build whose Default lacks that field
	holds it, the same as a game op it cannot apply.

	Hint names the field taking the most room. Blocked names the kind that stops a key compacting.
	Swells says whether an op would take a state past its cap. It reads the cached size first and
	folds only a key that is near the cap.

	Return type: A table with Packed, Swells, Oversized, Overgrown, Bulk, Hint, Blocked and SEEN_LIMIT.
	Example usage:
		local Compact = require("./Compact")
		if Compact.Overgrown(Record) then Fold() end
--]=]

local Clock = require("../Util/Clock")
local TableUtil = require("../Util/TableUtil")
local Sizes = require("../Core/Constants/Sizes")
local Measure = require("../Encode/Measure")
local Storable = require("../Encode/Storable")
local Kinds = require("../Core/Constants/Kinds")
local Shapes = require("../Core/Shapes")
local Tags = require("../Core/Constants/Tags")
local Applied = require("../Core/Applied")
local Schema = require("./Schema")
local TxStamp = require("./TxStamp")
local Apply = require("./Apply")
local Types = require("./Types")

type Op = Shapes.Op
type Record = Shapes.Record<any>
type Run = Shapes.Run
type Schema<S> = Types.Shape<S>

local SEEN_LIMIT = 2048
local RUNS = 16

local COMPACT_OPS = 128
local COMPACT_CEILING = 512
local COMPACT_SHARE = 0.2

local function Oversized(Ops: number, Bytes: number, State: number): boolean
	if Ops >= COMPACT_CEILING or Bytes >= Sizes.Compact then
		return true
	end
	if Ops < COMPACT_OPS then
		return false
	end
	return Bytes >= State * COMPACT_SHARE
end

local function Bulk(Record: Record): number
	if type(Record.Bytes) == "number" then
		return Record.Bytes
	end
	return Measure(Record.Snapshot)
end

local function Swells(Record: Record, Format: Schema<any>, Op: Op): boolean
	if Bulk(Record) + Measure(Record.Ops) + Measure(Op) <= Sizes.StateFloor then
		return false
	end

	local Folded = Format:Fold(Schema.Detached(Record))
	local Next = Apply(Format.Reducer, Folded, Op)
	if Next == nil then
		return false
	end

	local Bytes = Measure(Next)
	return Bytes > Sizes.State and Bytes > Measure(Folded)
end

local function Overgrown(Record: Record): boolean
	local Count = #Record.Ops
	local Bytes = Measure(Record.Ops)
	if Count < COMPACT_OPS then
		return Bytes >= Sizes.Compact
	end

	return Oversized(Count, Bytes, Bulk(Record))
end

local function Conditioned(State: any, Op: Op): boolean
	local Needed = Op.TxOnly
	if Needed == true then
		return true
	end
	if type(Needed) ~= "table" or #Needed == 0 then
		return false
	end

	for _, Txid in Needed :: { string } do
		if Applied.Has((State :: any)._Received, Tags.TX, Txid) then
			return false
		end
	end
	return true
end

local function Knows(State: any, Op: Op): boolean
	local Field = Op.Field
	return type(Field) ~= "string" or (type(State) == "table" and type(State[Field]) == "number")
end

local function Accounted(State: any, Op: Op, Format: Schema<any>): boolean
	local Handles = Format.Handles
	if if Handles ~= nil then Handles[Op.Kind] == true else Storable.Reserved(Op.Kind) then
		return Knows(State, Op)
	end

	if Conditioned(State, Op) then
		return true
	end

	local Data: any = State
	if type(Op.Once) == "string" and Applied.Has(Data._Received, Tags.ONCE, Op.Once) then
		return true
	end
	return type(Op.TxSticky) == "string" and Applied.Has(Data._Received, Tags.TX, Op.TxSticky)
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

local function Blocked(Record: Record, Format: Schema<any>): string?
	if #Record.Ops == 0 or TxStamp.HasPending(Record) then
		return nil
	end

	local _, Taken, Held = Absorbable(Record, Format)
	return if Taken == 0 then Held else nil
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

local function Dropped(Runs: { Run }, Total: number, Overflow: number, Horizon: number?): ({ Run }, number?)
	local Covered = 0
	for _, Run in Runs do
		Covered += Run.Count
	end

	local Drop = Overflow - (Total - Covered)
	local Kept: { Run } = {}
	local Newest = Horizon
	for _, Run in Runs do
		if Drop <= 0 then
			table.insert(Kept, Run)
			continue
		end

		Newest = if Newest == nil then Run.At else math.max(Newest, Run.At)
		if Run.Count > Drop then
			table.insert(Kept, { At = Run.At, Count = Run.Count - Drop })
		end
		Drop -= Run.Count
	end
	return Kept, Newest
end

local function Merged(Runs: { Run }): { Run }
	local Held = Runs
	while #Held > RUNS do
		local First, Second = Held[1], Held[2]
		Held = table.move(Held, 3, #Held, 2, { { At = math.max(First.At, Second.At), Count = First.Count + Second.Count } })
	end
	return Held
end

local function Packed(Key: string, Record: Record, Format: Schema<any>): Record?
	if TxStamp.HasPending(Record) then
		return nil
	end

	local Snapshot, Taken, Blocking = Absorbable(Record, Format)
	if Taken == 0 and #Record.Ops > 0 then
		warn(`Ledger: key '{Key}' cannot be compacted, its oldest op is a '{Blocking}' this build does not apply. a build that does apply it compacts the key`)
		return nil
	end

	local Fits, Where = Storable.Structure(Snapshot)
	if not Fits then
		warn(
			`Ledger: key '{Key}' cannot be compacted, your reducer built state a datastore cannot hold, {Where}. the log is left alone rather than lose that field. no gaps in arrays, no mixing array and string keys, no nan`
		)
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
	local Runs: { Run } = table.clone(Record.Absorbed or {})
	if Taken > 0 then
		table.insert(Runs, { At = Clock.Now(), Count = Taken })
	end

	local Horizon = Record.Horizon
	local Keep = math.max(SEEN_LIMIT, Taken)
	local Overflow = #Seen - Keep
	if Overflow > 0 then
		Runs, Horizon = Dropped(Runs, #Seen, Overflow, Horizon)
		Seen = table.move(Seen, Overflow + 1, #Seen, 1, {})
	end
	Runs = Merged(Runs)

	local Steps = Format.Migrations
	local Stored = Record.Version or 0
	local Ahead = Stored > #Steps

	local Fresh: Record = {
		Envelope = Kinds.ENVELOPE,
		Snapshot = Snapshot,
		Bytes = Measure(Snapshot),
		Ops = Held,
		Seen = Seen,
		Erased = Record.Erased,
		Removing = Record.Removing,
		Horizon = Horizon,
		Absorbed = if #Runs > 0 then Runs else nil,
		Version = if Ahead then Stored else #Steps,
		Floor = if Ahead then Record.Floor or Stored else Schema.FloorOf(Steps),
	}

	assert((Fresh.Floor :: number) >= (Record.Floor or 0), `compacting '{Key}' lowered the version floor, so a server that cannot read it would think it can`)

	return Fresh
end

return table.freeze({
	Packed = Packed,
	Swells = Swells,
	Oversized = Oversized,
	Overgrown = Overgrown,
	Bulk = Bulk,
	Hint = Hint,
	Blocked = Blocked,
	SEEN_LIMIT = SEEN_LIMIT,
})
