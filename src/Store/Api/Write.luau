--!strict
--!optimize 2

--[=[

	Write: Puts one op on one key, and reads what the record folds to.

	Every public write ends here, and this is the only place that turns a datastore answer into a
	reason. It runs the caller's guard, asks whether the op still applies, appends, settles and trims
	the record, then reads back whether the op really took. Shows is for a caller whose op can land and
	still leave nothing behind, because a later op undid it: it is asked once of the settled record and
	names the reason. An op that only holds because a transaction is parked carries which ones, so a
	later compaction can tell a commit from an abandonment, and one that only holds if the transaction
	does not go through is not written at all, since once the leg lands it could never fold or compact.
	It also adds a key to the sweep when that key is left holding money mid move.

	Return type: A table with Failed. It writes Stale, Went, Watch, WatchHeld, Append, Swelling, Starved, Maintain, Applies, Swollen and Written onto the class.
	Example usage:
		local Write = require("./Write")
		local Ok, Why = self:Written("1", Op, "edit")
--]=]

local TableUtil = require("../../Util/TableUtil")
local Clock = require("../../Util/Clock")
local Observer = require("../../Util/Observer")
local Windows = require("../../Core/Constants/Windows")
local Sizes = require("../../Core/Constants/Sizes")
local Errors = require("../../Core/Errors")
local Reasons = require("../../Core/Constants/Reasons")
local Shapes = require("../../Core/Shapes")
local Measure = require("../../Encode/Measure")
local Compact = require("../../Record/Compact")
local Schema = require("../../Record/Schema")
local TxStamp = require("../../Record/TxStamp")
local Apply = require("../../Record/Apply")
local Tx = require("../../Protocol/Tx")
local Store = require("../Class")
local Types = require("../Types")

type Op = Shapes.Op
type Record = Shapes.Record<any>
type Reason = Reasons.Reason
type Store = Types.Store<any>
type Allow = Types.Allow

local REFUSED = Reasons.Refused
local UNRESOLVED = Reasons.Unresolved
local BUSY = Reasons.Busy
local CLOSED = Reasons.Closed
local BEHIND = Reasons.Behind
local FULL = Reasons.Full

local function Failed(What: string, Key: string, Err: any): Reason
	local Why = Errors.Reason(Err)
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

function Store.Stale(self: Store): Observer.Observer<string>
	return self.Staleness
end

function Store.Went(self: Store, Key: string)
	self.Staleness:Push(Key)
end

function Store.Watch(self: Store, Key: string, Record: Record)
	if TxStamp.HasPending(Record) then
		self.Sweep:Add(self:Swept(), Key)
	end
end

function Store.WatchHeld(self: Store, Key: string, State: any)
	if type(State) ~= "table" then
		return
	end

	if TableUtil.Occupied(State._Held) or TableUtil.Occupied(State._Booked) then
		self.Sweep:Add(self:Swept(), Key)
	end
end

function Store.Append(self: Store, Key: string, Op: Op, Guard: Allow?): Record
	return (self:Records():Append(Key, { Op }, Guard))
end

function Store.Swelling(self: Store, Key: string, Record: Record)
	local Meter = self.Meter
	Meter.Swollen += 1

	local Now = Clock.Now()
	if Now - Meter.Said < Windows.AUTOSAVE then
		return
	end

	local Blocking = "a transaction"
	for Txid in TxStamp.PendingTx(Record) do
		Blocking = `transaction '{Txid}'`
		break
	end

	warn(
		`Ledger: '{Key}' holds {#Record.Ops} ops it cannot compact away while {Blocking} is parked on it. it keeps growing until that settles. {Meter.Swollen} write(s) since the last of these`
	)

	Meter.Swollen = 0
	Meter.Said = Now
end

function Store.Starved(self: Store, Pool: Enum.DataStoreRequestType)
	local Meter = self.Meter
	Meter.Skipped += 1

	local Now = Clock.Now()
	if Now - Meter.At < Windows.AUTOSAVE then
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
	if TxStamp.HasPending(Record) then
		local Ok, Resolution = pcall(function(): Record
			return Tx.Settle(self:Records(), self.TxWrapper, Key, Record)
		end)
		if Ok then
			Settled = Resolution
		else
			warn(`Ledger: a transaction parked on '{Key}' could not be settled during a write, so it stays parked: {Resolution}`)
		end
	end

	self:Watch(Key, Settled)
	local Trimmed = self:Records():Trim(Key, self:Format(), Settled)
	if TxStamp.HasPending(Trimmed) and Compact.Overgrown(Trimmed) then
		self:Swelling(Key, Trimmed)
	end
	return Settled
end

function Store.Applies(self: Store, Op: Op, Record: Record): (boolean, boolean, boolean)
	if TxStamp.Carries(Record, Op.Id) then
		return true, false, false
	end

	local Read, Holds, Only, Doubt = pcall(function(): (boolean, boolean, boolean)
		local Format = self:Format()
		local Plain = Apply(Format.Reducer, Format:Fold(Schema.Detached(Record)), Op) ~= nil
		if not TxStamp.HasPending(Record) then
			return Plain, false, false
		end

		local Committed = Schema.Detached(Record)
		Committed.Ops = TxStamp.Landed(Record.Ops, nil)
		local Landed = Apply(Format.Reducer, Format:Fold(Committed), Op) ~= nil
		if Plain == Landed then
			return Plain, false, false
		end
		return Landed, Landed, Plain
	end)
	if not Read then
		return true, false, false
	end
	return Holds, Only, Doubt
end

function Store.Swollen(self: Store, Op: Op, Record: Record): boolean
	if Compact.Bulk(Record) + Measure(Record.Ops) + Measure(Op) <= Sizes.StateFloor then
		return false
	end

	local Read, Over = pcall(function(): boolean
		local Format = self:Format()
		local Folded = Format:Fold(Schema.Detached(Record))
		local Next = Apply(Format.Reducer, Folded, Op)
		if Next == nil then
			return false
		end

		local Bytes = Measure(Next)
		return Bytes > Sizes.State and Bytes > Measure(Folded)
	end)
	return Read and Over
end

function Store.Written(self: Store, Key: string, Op: Op, What: string, Guard: Allow?, Denied: Reason?, Shows: ((Record) -> Reason?)?): (boolean, Reason?)
	local Applied = true
	local Swollen = false
	local Doubt = false
	local Landed, Result = pcall(function(): Record
		return self:Append(Key, Op, function(Record: Record): boolean
			Applied, Swollen, Doubt = true, false, false
			if Guard ~= nil and not Guard(Record) then
				return false
			end

			local Only
			Applied, Only, Doubt = self:Applies(Op, Record)
			if not Applied then
				return false
			end
			(Op :: any).TxOnly = if Only then TxStamp.PendingIds(Record) else nil

			Swollen = self:Swollen(Op, Record)
			return not Swollen
		end)
	end)

	if not Landed then
		local Named = Errors.Reason(Result)
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
		warn(`Ledger: {What} on '{Key}' was not written, that key is already at the {Sizes.State} byte state cap and this would make it bigger`)
		return false, FULL
	end
	if Doubt then
		warn(`Ledger: {What} on '{Key}' was not written, a transaction is parked on that key and this op only holds if it does not go through. ask again once it settles`)
		return false, UNRESOLVED
	end
	if not Applied then
		return false, REFUSED
	end

	local Ok, Why = pcall(function(): Reason?
		local Settled = self:Maintain(Key, Stored)
		if not TxStamp.Holds(Settled, Op.Id) then
			return UNRESOLVED
		end

		local Took, Sure = self:Format():Certain(Settled, Op.Id)
		assert(Sure or TxStamp.HasPending(Settled), `the answer for {What} on '{Key}' is unsure while nothing is pending there, so a settled key is reporting doubt`)
		if not Sure then
			return UNRESOLVED
		end
		if not Took then
			return REFUSED
		end
		if Shows ~= nil then
			return Shows(Settled)
		end
		return nil
	end)

	if not Ok then
		warn(`Ledger: {What} on '{Key}' went into the log, but this server could not read the record back to say what it folded to: {Why}`)
		return false, UNRESOLVED
	end

	if Why == nil then
		self:Went(Key)
	end
	return Why == nil, Why
end

return table.freeze({
	Failed = Failed,
})
