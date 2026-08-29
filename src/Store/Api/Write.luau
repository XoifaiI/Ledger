--!strict
--!optimize 2

--[=[
	Write: Puts one op on one key. Reads what the record folds to.

	Every public write ends here. This is the only place that turns a datastore answer into a reason.
	The steps run in a fixed order: the guard of the caller, Applies, the append, Maintain, then
	Certain. Each step gives a different answer when it fails.
	Write also holds the key to the state cap, and adds a key to the sweep when that key holds money
	in the middle of a move.

	Return type: A table with Failed, Watch, WatchHeld, Stale, Went, Append, Maintain, Applies, Written, Swelling and Starved.
	Example usage:
		local Write = require("./Write")
		local Ok, Why = self:Written("1", Op, "edit")
--]=]

local Warnings = require("../../Util/Warnings")
local TableUtil = require("../../Util/TableUtil")
local Clock = require("../../Util/Clock")
local Observer = require("../../Util/Observer")
local Errors = require("../../Core/Errors")
local Windows = require("../../Core/Constants/Windows")
local Sizes = require("../../Core/Constants/Sizes")
local Reasons = require("../../Core/Reasons")
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
	local Why = Errors.Named(Err)
	if Why == CLOSED then
		return Why
	end

	if Why == BEHIND then
		Warnings.Warn(`Ledger: could not {What} '{Key}', a newer server wrote it and this one cannot read that yet. finish the deploy: {Err}`)
		return Why
	end

	Warnings.Warn(`Ledger: could not {What} '{Key}': {Err}`)
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

	Warnings.Warn(
		`Ledger: '{Key}' is carrying {#Record.Ops} ops it cannot compact away because {Blocking} is still parked on it, so the record keeps growing until that settles. {Meter.Swollen} write(s) since the last of these`
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

	Warnings.Warn(
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
			Warnings.Warn(`Ledger: could not settle a pending transaction leg on '{Key}' during a write, so it stays pending: {Resolution}`)
		end
	end

	self:Watch(Key, Settled)
	local Trimmed = self:Records():Trim(Key, self:Format(), Settled)
	if TxStamp.HasPending(Trimmed) and Compact.Overgrown(Trimmed) then
		self:Swelling(Key, Trimmed)
	end
	return Settled
end

function Store.Applies(self: Store, Op: Op, Record: Record): (boolean, boolean)
	if TxStamp.Carries(Record, Op.Id) then
		return true, false
	end

	local Read, Holds, Only = pcall(function(): (boolean, boolean)
		local Format = self:Format()
		if Apply(Format.Reducer, Format:Fold(Schema.Detached(Record)), Op) ~= nil then
			return true, false
		end
		if not TxStamp.HasPending(Record) then
			return false, false
		end

		local Committed = Schema.Detached(Record)
		Committed.Ops = TxStamp.Landed(Record.Ops, nil)
		return Apply(Format.Reducer, Format:Fold(Committed), Op) ~= nil, true
	end)
	if not Read then
		return true, false
	end
	return Holds, Holds and Only
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

function Store.Written(self: Store, Key: string, Op: Op, What: string, Guard: Allow?, Denied: Reason?): (boolean, Reason?)
	local Applied = true
	local Swollen = false
	local Landed, Result = pcall(function(): Record
		return self:Append(Key, Op, function(Record: Record): boolean
			Applied, Swollen = true, false
			if Guard ~= nil and not Guard(Record) then
				return false
			end

			local Only
			Applied, Only = self:Applies(Op, Record)
			if not Applied then
				return false
			end
			if Only then
				(Op :: any).TxOnly = true
			end

			Swollen = self:Swollen(Op, Record)
			return not Swollen
		end)
	end)

	if not Landed then
		local Named = Errors.Named(Result)
		if Named == CLOSED then
			return false, CLOSED
		end
		if Named == BEHIND then
			Warnings.Warn(`Ledger: {What} on '{Key}' was not written, a newer server wrote that record and this one cannot read it yet. finish the deploy: {Result}`)
			return false, BEHIND
		end
		if Named == FULL then
			Warnings.Warn(`Ledger: {What} on '{Key}' was not written, that key is carrying more unsaved ops than it can hold: {Result}`)
			return false, FULL
		end
		if Named == BUSY then
			return false, BUSY
		end

		Warnings.Warn(`Ledger: {What} on '{Key}' could not be written, though it might still have gone through: {Result}`)
		return false, UNRESOLVED
	end

	local Stored: Record = Result
	if Guard ~= nil and not Guard(Stored) then
		return false, Denied or REFUSED
	end
	if Swollen then
		Warnings.Warn(`Ledger: {What} on '{Key}' was not written, that key is already at the {Sizes.State} byte state cap and this would make it bigger`)
		return false, FULL
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
		Errors.Holds(Sure or TxStamp.HasPending(Settled), `the answer for {What} on '{Key}' is unsure while nothing is pending there, so a settled key is reporting doubt`)
		if not Sure then
			return UNRESOLVED
		end
		return if Took then nil else REFUSED
	end)

	if not Ok then
		Warnings.Warn(`Ledger: {What} on '{Key}' went into the log, but this server could not read the record back to say what it folded to: {Why}`)
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
