--!strict
--!optimize 2

--[=[
	Write: Puts one op on one key, and reads what the record folds to.
	
	Each public write ends here. This is the one place that turns a datastore answer into a reason.
	The order is fixed. The guard of the caller runs first, then Applies, then the append, then
	Maintain, then Certain. Each step has a different answer when it fails.
	The state cap is checked here as well, so a key cannot be grown past it by Edit and the money
	methods the way it could before. The check is the cheap one first, the size the record already
	carries, and it only folds when the key is near the cap. An op that makes an oversized profile
	smaller is still allowed.
	The sweep follows a key that holds money in the middle of a move, or units set aside. A read is
	what puts it there, so a key that nobody writes to again is still reached.
	Applies refuses an op that the reducer would refuse, so a log does not fill with ops that do
	nothing. Each case that is not certain writes instead. To refuse a write that should have
	happened is the worse fault.
	A key with a leg parked on it is asked twice, once against what it holds now and once against
	what the leg committing would give. An op that holds either way is written. An op that holds
	neither way never will, and writing it would stop the key from compacting for good.
	
	Return type: A table with Failed, Watch, WatchHeld, Append, Maintain, Applies, Written, Swelling, Starved and AUTOSAVE_INTERVAL.
	Example usage:
		local Write = require("./Write")
		local Ok, Why = self:Written("1", Op, "edit")
--]=]

local TableUtil = require("../Util/TableUtil")
local Clock = require("../Util/Clock")
local Fault = require("../Contract/Fault")
local Reasons = require("../Contract/Reason")
local Contract = require("../Contract/Op")
local Measure = require("../Encode/Measure")
local IsStorable = require("../Encode/Storable")
local Compact = require("../Record/Compact")
local Shape = require("../Record/Shape")
local Stamp = require("../Record/Stamp")
local Step = require("../Record/Step")
local Tx = require("../Protocol/Tx")
local Registry = require("./Registry")
local Store = require("./Class")
local Types = require("./Types")

type Op = Contract.Op
type Record = Contract.Record<any>
type Reason = Reasons.Reason
type Store = Types.Store
type Allow = Types.Allow

local AUTOSAVE_INTERVAL = 30

local MAX_STATE_BYTES = Contract.MAX_STATE_BYTES
local STATE_CHECK_FLOOR = MAX_STATE_BYTES - IsStorable.MAX_BYTES

local REFUSED = Reasons.Refused
local UNRESOLVED = Reasons.Unresolved
local BUSY = Reasons.Busy
local CLOSED = Reasons.Closed
local BEHIND = Reasons.Behind
local FULL = Reasons.Full

local function Failed(What: string, Key: string, Err: any): Reason
	local Why = Fault.Named(Err)
	if Why == CLOSED then
		return Why
	end

	if Why == BEHIND then
		warn(`Ledger: could not {What} '{Key}', a newer server wrote it and this one cannot read that yet. finish the deploy: {Err}`)
		return Why
	end

	warn(`Ledger: could not {What} '{Key}': {Err}`)
	return Why
end

function Store.Watch(self: Store, Key: string, Record: Record)
	if Stamp.HasPending(Record) then
		Registry.Sweep():Add(self, Key)
	end
end

function Store.WatchHeld(self: Store, Key: string, State: any)
	if type(State) ~= "table" then
		return
	end

	if TableUtil.Occupied(State._Held) or TableUtil.Occupied(State._Booked) then
		Registry.Sweep():Add(self, Key)
	end
end

function Store.Append(self: Store, Key: string, Op: Op, Guard: Allow?): Record
	return (self:Records():Append(Key, { Op }, Guard))
end

function Store.Swelling(self: Store, Key: string, Record: Record)
	local Meter = self.Meter
	Meter.Swollen += 1

	local Now = Clock.Now()
	if Now - Meter.Said < AUTOSAVE_INTERVAL then
		return
	end

	local Blocking = "a transaction"
	for Txid in Stamp.PendingTx(Record) do
		Blocking = `transaction '{Txid}'`
		break
	end

	warn(
		`Ledger: '{Key}' is carrying {#Record.Ops} ops it cannot compact away because {Blocking} is still parked on it, so the record keeps growing until that settles. {Meter.Swollen} write(s) since the last of these`
	)

	Meter.Swollen = 0
	Meter.Said = Now
end

function Store.Starved(self: Store, Pool: Enum.DataStoreRequestType)
	local Meter = self.Meter
	Meter.Skipped += 1

	local Now = Clock.Now()
	if Now - Meter.At < AUTOSAVE_INTERVAL then
		return
	end

	local Records = self.Wrapper.Spent - Meter.Records
	local Markers = self.TxWrapper.Spent - Meter.Markers

	warn(
		`Ledger: {Meter.Skipped} autosave(s) skipped on '{self.Options.Name}' with {Pool.Name} budget at {self.Wrapper:Budget(Pool)}, so unsaved ops are piling up. this server spent {Records} request(s) on records and {Markers} on transaction markers since the last of these`
	)

	Meter.Skipped = 0
	Meter.At = Now
	Meter.Records = self.Wrapper.Spent
	Meter.Markers = self.TxWrapper.Spent
end

function Store.Maintain(self: Store, Key: string, Record: Record): Record
	local Settled = Record
	if Stamp.HasPending(Record) then
		local Ok, Resolution = pcall(function(): Record
			return Tx.Settle(self:Records(), self.TxWrapper, Key, Record)
		end)
		if Ok then
			Settled = Resolution
		else
			warn(`Ledger: could not settle a pending transaction leg on '{Key}' during a write, so it stays pending: {Resolution}`)
		end
	end

	self:Watch(Key, Settled)
	local Trimmed = self:Records():Trim(Key, self:Format(), Settled)
	if Stamp.HasPending(Trimmed) and Compact.Overgrown(Trimmed) then
		self:Swelling(Key, Trimmed)
	end
	return Settled
end

function Store.Applies(self: Store, Op: Op, Record: Record): boolean
	if Stamp.Carries(Record, Op.Id) then
		return true
	end

	local Read, Holds = pcall(function(): boolean
		local Format = self:Format()
		if Step(Format.Reducer, Format:Fold(Shape.Detached(Record)), Op) ~= nil then
			return true
		end
		if not Stamp.HasPending(Record) then
			return false
		end

		local Committed = Shape.Detached(Record)
		Committed.Ops = Stamp.Landed(Record.Ops, nil)
		return Step(Format.Reducer, Format:Fold(Committed), Op) ~= nil
	end)
	return not Read or Holds
end

function Store.Swollen(self: Store, Op: Op, Record: Record): boolean
	if Compact.Bulk(Record) + Measure(Record.Ops) + Measure(Op) <= STATE_CHECK_FLOOR then
		return false
	end

	local Read, Over = pcall(function(): boolean
		local Format = self:Format()
		local Folded = Format:Fold(Shape.Detached(Record))
		local Next = Step(Format.Reducer, Folded, Op)
		if Next == nil then
			return false
		end

		local Bytes = Measure(Next)
		return Bytes > MAX_STATE_BYTES and Bytes > Measure(Folded)
	end)
	return Read and Over
end

function Store.Written(self: Store, Key: string, Op: Op, What: string, Guard: Allow?, Denied: Reason?): (boolean, Reason?)
	local Applied = true
	local Swollen = false
	local Landed, Result = pcall(function(): Record
		return self:Append(Key, Op, function(Record: Record): boolean
			Applied, Swollen = true, false
			if Guard ~= nil and not Guard(Record) then
				return false
			end

			Applied = self:Applies(Op, Record)
			if not Applied then
				return false
			end

			Swollen = self:Swollen(Op, Record)
			return not Swollen
		end)
	end)

	if not Landed then
		local Named = Fault.Named(Result)
		if Named == CLOSED then
			return false, CLOSED
		end
		if Named == BEHIND then
			warn(`Ledger: {What} on '{Key}' was not written, a newer server wrote that record and this one cannot read it yet. finish the deploy: {Result}`)
			return false, BEHIND
		end
		if Named == FULL then
			warn(`Ledger: {What} on '{Key}' was not written, that key is carrying more unsaved ops than it can hold: {Result}`)
			return false, FULL
		end
		if Named == BUSY then
			return false, BUSY
		end

		warn(`Ledger: {What} on '{Key}' could not be written, though it might still have gone through: {Result}`)
		return false, UNRESOLVED
	end

	local Stored: Record = Result
	if Guard ~= nil and not Guard(Stored) then
		return false, Denied or REFUSED
	end
	if Swollen then
		warn(`Ledger: {What} on '{Key}' was not written, that key is already at the {MAX_STATE_BYTES} byte state cap and this would make it bigger`)
		return false, FULL
	end
	if not Applied then
		return false, REFUSED
	end

	local Ok, Why = pcall(function(): Reason?
		local Settled = self:Maintain(Key, Stored)
		if not Stamp.Holds(Settled, Op.Id) then
			return UNRESOLVED
		end

		local Took, Sure = self:Format():Certain(Settled, Op.Id)
		Fault.Holds(
			Sure or Stamp.HasPending(Settled),
			`the answer for {What} on '{Key}' is unsure while nothing is pending there, so a settled key is reporting doubt`
		)
		if not Sure then
			return UNRESOLVED
		end
		return if Took then nil else REFUSED
	end)

	if not Ok then
		warn(`Ledger: {What} on '{Key}' went into the log, but this server could not read the record back to say what it folded to: {Why}`)
		return false, UNRESOLVED
	end
	return Why == nil, Why
end

return table.freeze({
	Failed = Failed,
	AUTOSAVE_INTERVAL = AUTOSAVE_INTERVAL
})
