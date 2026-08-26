--!strict
--!optimize 2

--[=[
	Drive: Runs one transaction.

	Drive parks each leg on its key. One write to the marker then decides the whole set. Drive
	resolves each leg against that decision last.
	A coordinator that stops between two steps leaves a marker, and another server decides it.
	The marker decides, and not the server that asked. A server that wanted to cancel but finds the
	marker committed must resolve every leg.
	A drive that took longer than a transaction may writes its name on the cleanup list again, because
	a reaper that read the list while the marker was still unwritten will have taken the name off it.

	Return type: A table with Drive, LEG_TIMEOUT, TIMEOUT, MAX_LEGS and PASSES.
	Example usage:
		local Drive = require("./Drive")
		local Ok, Why = Drive.Drive(TxStore, Legs, "trade1")
--]=]

local Say = require("../../Util/Say")
local Clock = require("../../Util/Clock")
local TableUtil = require("../../Util/TableUtil")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local Fault = require("../../Contract/Fault")
local Reasons = require("../../Contract/Reason")
local Contract = require("../../Contract/Op")
local Fingerprint = require("../../Encode/Fingerprint")
local Mark = require("../../Encode/Mark")
local IsStorable = require("../../Encode/Storable")
local Log = require("../../Record/Log")
local Stamp = require("../../Record/Stamp")
local Marker = require("./Marker")
local Roll = require("./Roll")
local Settle = require("./Settle")
local Types = require("./Types")

type Op = Contract.Op
type Reason = Reasons.Reason
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Leg = Types.Leg
type Pass = Types.Pass

local LEG_TIMEOUT = Marker.LEG_TIMEOUT
local TIMEOUT = LEG_TIMEOUT * 2
local MAX_LEGS = Marker.MAX_LEGS
local PASSES = 3

local REFUSED = Reasons.Refused
local BUSY = Reasons.Busy
local SPENT = Reasons.Spent
local FULL = Reasons.Full
local UNRESOLVED = Reasons.Unresolved

local Canon = Fingerprint.Canon

local function PrepareLeg(Leg: Leg, Op: Op, PerLeg: number?): Log.Prepared
	local Verdict = Leg.Log:Prepare(Leg.Key, Op, Leg.Shape)
	if Verdict ~= Log.Verdict.Busy then
		return Verdict
	end

	local Record = Settle.Settle(Leg.Log, Leg.TxStore, Leg.Key, Leg.Log:Read(Leg.Key), PerLeg)
	if Stamp.HasPending(Record) then
		return Log.Verdict.Busy
	end

	return Leg.Log:Prepare(Leg.Key, Op, Leg.Shape)
end

local function Stamped(Ops: { Op }, Gen: string?, Born: number, Print: string)
	for _, Op in Ops do
		Op.TxGen = Gen
		Op.TxAt = Born
		Op.TxTerms = Print
	end
end

local function Adopted(Legs: { Leg }, Txid: string, Verdict: Log.Verdict, Upto: number, Tidy: boolean): ({ string }, number)
	Fault.Holds(Upto <= #Legs, `transaction '{Txid}' is resolving more legs than it has`)
	Fault.Holds(not Verdict.Commit or Upto == #Legs, `transaction '{Txid}' is committing without resolving every one of its legs`)

	local Marks: { string } = {}
	local Left = 0
	for Index = 1, Upto do
		local Leg = Legs[Index]
		local Ok, Settlement = pcall(function()
			return Leg.Log:Resolve(Leg.Key, { [Txid] = Verdict })
		end)
		if not Ok then
			Left += 1
			continue
		end

		if Settlement.Counts[Txid] then
			table.insert(Marks, Marker.MarkOf(Leg.Log.Wrapper, Leg.Key))
			if Tidy then
				Leg.Log:Trim(Leg.Key, Leg.Shape, Settlement.Record)
			end
		end
	end
	return Marks, Left
end

local function Heal(TxStore: DataStoreWrapper, Legs: { Leg }, Txid: string, Gen: string?, Born: number): number
	local Verdict: Log.Verdict = { Commit = false, Gen = Gen, Since = Born }
	local Marks, Left = Adopted(Legs, Txid, Verdict, #Legs, false)
	Marker.Adopt(TxStore, Txid, Marks, Gen)
	Marker.Decide(TxStore, Txid, Marker.ABORTED, 0, Gen)
	return Left
end

local function PrepareAll(Legs: { Leg }, Ops: { Op }, Floor: number, PerLeg: number?): (number, number, Reason?)
	local Prepared = Floor
	local Settled = 0

	for Index, Leg in Legs do
		local Fine, Verdict = pcall(PrepareLeg, Leg, Ops[Index], PerLeg)

		if not Fine then
			return Prepared, Settled, UNRESOLVED
		end

		if Verdict == "Settled" then
			Settled += 1
			Prepared = math.max(Prepared, Index)
		elseif Verdict == "Prepared" then
			Prepared = math.max(Prepared, Index)
		elseif Verdict == "Busy" then
			return Prepared, Settled, BUSY
		elseif Verdict == "Spent" then
			Say.Warn(
				`Ledger: transaction '{Ops[Index].Tx}' was already used for different keys or a different amount, and a name has to mean the same thing every time. nothing was applied, so pick a new name`
			)
			return Prepared, Settled, SPENT
		elseif Verdict == "Rejected" then
			return Prepared, Settled, REFUSED
		elseif Verdict == "Full" then
			Say.Warn(`Ledger: transaction '{Ops[Index].Tx}' cannot put a leg on '{Legs[Index].Key}', that key is carrying more ops than it can hold until it compacts. nothing was applied`)
			return Prepared, Settled, FULL
		else
			local Unreachable: never = Verdict
			return Prepared, Settled, Unreachable
		end
	end

	return Prepared, Settled, nil
end

local function RunOnce(TxStore: DataStoreWrapper, Legs: { Leg }, Ops: { Op }, Txid: string, Keys: string, Terms: string, Print: string, Floor: number, PerLeg: number?): Pass
	local Created, Gen, Born, Minted = Marker.Create(TxStore, Txid, #Legs, Keys, Terms)
	if Created == Marker.MISMATCH then
		Say.Warn(`Ledger: transaction '{Txid}' was already used for different keys or a different amount, and a name has to mean the same thing every time. nothing was applied, so pick a new name`)
		return { Committed = false, Why = SPENT, Again = false, Reached = Floor, Parked = Floor > 0 }
	end
	if Created == Marker.UNWRITTEN then
		return { Committed = false, Why = UNRESOLVED, Again = true, Reached = Floor, Parked = Floor > 0 }
	end

	Stamped(Ops, Gen, Born, Print)

	if Created == Marker.HUSK then
		return { Committed = false, Why = SPENT, Again = true, Reached = Floor, Parked = Heal(TxStore, Legs, Txid, Gen, Born) > 0 }
	end

	local Prepared, Settled, Cause = PrepareAll(Legs, Ops, Floor, PerLeg)
	local Clean = Cause == nil
	Fault.Holds(Settled <= #Legs, "more legs reported as already settled than the transaction has")
	Fault.Holds(Prepared <= #Legs, "the transaction prepared past its own last leg")

	if Clean and Settled == #Legs then
		Marker.Decide(TxStore, Txid, Marker.ABORTED, 0, Gen)
		return { Committed = true, Why = nil, Again = false, Reached = Prepared, Parked = false }
	end

	local Split = Clean and Settled > 0
	local Aborting = not Clean or Split
	local Disown = Cause == SPENT and Minted
	local Shrink = if Aborting then (if Disown then 0 else Prepared) else nil
	local Final = Marker.Decide(TxStore, Txid, if Aborting then Marker.ABORTED else Marker.COMMITTED, Shrink, Gen)
	if Final == nil then
		return { Committed = false, Why = UNRESOLVED, Again = true, Reached = Prepared, Parked = Prepared > 0 }
	end

	local Landed = Final == Marker.COMMITTED
	local Verdict: Log.Verdict = { Commit = Landed, Gen = Gen, Since = Born }
	local Marks, Left = Adopted(Legs, Txid, Verdict, if Landed then #Legs else Prepared, true)
	Marker.Adopt(TxStore, Txid, Marks, Gen)
	local Stranded = Left > 0

	if Landed then
		return { Committed = true, Why = nil, Again = false, Reached = Prepared, Parked = Stranded }
	end
	if not Aborting then
		return { Committed = false, Why = SPENT, Again = true, Reached = Prepared, Parked = Stranded }
	end
	if Split then
		Say.Warn(`Ledger: transaction '{Txid}' is only half remembered across its keys, so Ledger cancelled it rather than applying it to some keys and not others`)
		return { Committed = false, Why = SPENT, Again = false, Reached = Prepared, Parked = Stranded }
	end
	return { Committed = false, Why = Cause, Again = Cause == UNRESOLVED, Reached = Prepared, Parked = Stranded }
end

local function LegOp(Id: string, Index: number, Leg: Leg, Home: string): Op
	local Op: { [any]: any } = if Leg.Fields then TableUtil.DeepCopy(Leg.Fields) else {}
	if Op.Id ~= nil or Op.Kind ~= nil then
		Say.Warn(`Ledger: transaction leg '{Leg.Kind}' passed Id or Kind in its fields. those two belong to Ledger, so they got overwritten`)
	end
	Op.Id = `tx:{Id}:{Index}`
	Op.Kind = Leg.Kind

	local Storable, Unstorable = IsStorable.Op(Op :: Op)
	assert(Storable, `transaction leg '{Leg.Kind}' cannot be stored, {Unstorable}`)

	Op.Tx = Id
	Op.TxHome = Home
	Op.TxSticky = Id
	return Op :: Op
end

local function Drive(TxStore: DataStoreWrapper, Legs: { Leg }, Id: string, PerLeg: number?): (boolean, Reason?, boolean)
	assert(type(Id) == "string" and #Id > 0, "a transaction needs an Id, a stable name derived from the thing being settled")
	assert(#Legs >= 2 and #Legs <= MAX_LEGS, `a transaction takes 2 to {MAX_LEGS} legs, got {#Legs}`)
	assert(string.sub(Id, 1, #Roll.RESERVED) ~= Roll.RESERVED, `a transaction Id cannot start with '{Roll.RESERVED}', Ledger keeps that prefix for its own keys`)

	local Marks: { string } = {}
	local Terms: { string } = {}
	local Ops: { Op } = {}
	local Touched: { [string]: boolean } = {}

	for Index, Leg in Legs do
		local Held = Marker.MarkOf(Leg.Log.Wrapper, Leg.Key)
		assert(not Touched[Held], `a transaction may only touch a key once per store, '{Leg.Key}' appears twice`)
		Touched[Held] = true

		Marks[Index] = Held
		Terms[Index] = `{Leg.Kind}{Canon(Leg.Fields)}`
		Ops[Index] = LegOp(Id, Index, Leg, TxStore.Name)
	end

	local Keys = Mark.Pack(Marks)
	local Shape = Mark.Pack(Terms)
	local Print = Fingerprint.Of(Mark.Pack({ Keys, Shape }))

	local Added = Clock.Now()
	if not Roll.Add(TxStore, Id) then
		Say.Warn(`Ledger: transaction '{Id}' was not started, Ledger could not add it to the cleanup list. nothing was applied, try again`)
		return false, UNRESOLVED, false
	end

	local function Enrolled()
		if Clock.Now() - Added >= TIMEOUT then
			Roll.Add(TxStore, Id)
		end
	end

	local Last: Reason = UNRESOLVED
	local Floor = 0
	local Parked = false
	for _ = 1, PASSES do
		local Attempt = RunOnce(TxStore, Legs, Ops, Id, Keys, Shape, Print, Floor, PerLeg)
		Floor = Attempt.Reached
		Parked = Attempt.Parked
		if Attempt.Committed then
			Enrolled()
			return true, nil, Parked
		end

		if Attempt.Why ~= nil then
			Last = Attempt.Why
		end
		if not Attempt.Again then
			break
		end
	end

	if Last == UNRESOLVED then
		Say.Warn(`Ledger: transaction '{Id}' has no answer yet and might still go through. read the keys again instead of retrying it under a new name`)
	elseif Last == SPENT then
		Say.Warn(`Ledger: transaction '{Id}' could not get through and changed nothing. that name is spent now, so use a new one`)
	end

	Enrolled()
	return false, Last, Parked
end

return table.freeze({
	Drive = Drive,
	LEG_TIMEOUT = LEG_TIMEOUT,
	TIMEOUT = TIMEOUT,
	MAX_LEGS = MAX_LEGS,
	PASSES = PASSES,
})
