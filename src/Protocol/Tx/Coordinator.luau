--!strict
--!optimize 2

--[=[

	Coordinator: Runs one transaction.

	Drive parks a leg on each key, writes one decision to the marker, and resolves every leg against
	that decision. The marker decides and not the server that asked, so a coordinator that stops
	leaves a marker any other server can finish from. A pass that may open a generation puts the key
	of its marker on the cleanup list first, and every leg names that key. A marker that opened later
	than a reaper may judge that entry goes on the list again before any leg is parked. A later pass
	of the same drive joins the marker an earlier pass opened.

	Return type: A table with Drive.
	Example usage:
		local Coordinator = require("./Coordinator")
		local Ok, Why = Coordinator.Drive(TxStore, Legs, "trade1")
--]=]

local Clock = require("../../Util/Clock")
local TableUtil = require("../../Util/TableUtil")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local Windows = require("../../Core/Constants/Windows")
local Reasons = require("../../Core/Constants/Reasons")
local Verdicts = require("../../Core/Constants/Verdicts")
local Shapes = require("../../Core/Shapes")
local Digest = require("../../Encode/Digest")
local Ids = require("../../Encode/Ids")
local Mark = require("../../Encode/Mark")
local Storable = require("../../Encode/Storable")
local Log = require("../../Record/Log")
local TxStamp = require("../../Record/TxStamp")
local Transactions = require("../../Core/Constants/Transactions")
local Marker = require("./Marker")
local Cleanup = require("./Cleanup")
local Resolve = require("./Resolve")
local Types = require("./Types")

type Op = Shapes.Op
type Reason = Reasons.Reason
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Leg = Types.Leg
type Pass = Types.Pass

local REFUSED = Reasons.Refused
local BUSY = Reasons.Busy
local SPENT = Reasons.Spent
local FULL = Reasons.Full
local UNRESOLVED = Reasons.Unresolved

local Canon = Digest.Canon

local LATE = Windows.REAP_GRACE - Windows.BUCKET

local function PrepareLeg(Leg: Leg, Op: Op, PerLeg: number?): Log.Prepared
	local Verdict = Leg.Log:Prepare(Leg.Key, Op, Leg.Shape)
	if Verdict ~= Verdicts.BUSY then
		return Verdict
	end

	local Record = Resolve.Settle(Leg.Log, Leg.TxStore, Leg.Key, Leg.Log:Read(Leg.Key), PerLeg)
	if TxStamp.HasPending(Record) then
		return Verdicts.BUSY
	end

	return Leg.Log:Prepare(Leg.Key, Op, Leg.Shape)
end

local function Stamped(Ops: { Op }, Decides: string, Gen: string?, Born: number, Print: string)
	for _, Op in Ops do
		Op.Tx = Decides
		Op.TxGen = Gen
		Op.TxAt = Born
		Op.TxTerms = Print
	end
end

local function Adopted(Legs: { Leg }, Txid: string, Verdict: Log.Verdict, Upto: number, Tidy: boolean): ({ string }, number)
	assert(Upto <= #Legs, `transaction '{Txid}' is resolving more legs than it has`)
	assert(not Verdict.Commit or Upto == #Legs, `transaction '{Txid}' is committing without resolving every one of its legs`)

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
	Marker.Decide(TxStore, Txid, Transactions.ABORTED, 0, Gen)
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
			warn(`Ledger: transaction '{Ops[Index].TxSticky}' was already used for different keys or a different amount. nothing was applied, pick a new name`)
			return Prepared, Settled, SPENT
		elseif Verdict == "Rejected" then
			return Prepared, Settled, REFUSED
		elseif Verdict == "Full" then
			warn(`Ledger: transaction '{Ops[Index].TxSticky}' cannot touch '{Legs[Index].Key}', that key holds more unsaved ops than it can take. nothing was applied`)
			return Prepared, Settled, FULL
		elseif Verdict == "Erased" then
			warn(`Ledger: transaction '{Ops[Index].TxSticky}' cannot touch '{Legs[Index].Key}', that key was erased and is turned away until its tomb runs out. nothing was applied`)
			return Prepared, Settled, REFUSED
		else
			local Unreachable: never = Verdict
			return Prepared, Settled, Unreachable
		end
	end

	return Prepared, Settled, nil
end

local function RunOnce(
	TxStore: DataStoreWrapper,
	Legs: { Leg },
	Ops: { Op },
	Txid: string,
	Keys: string,
	Terms: string,
	Print: string,
	Floor: number,
	PerLeg: number?,
	Fresh: string,
	Own: string?,
	Home: string,
	Carried: number
): Pass
	local Created, Gen, Born, Minted, Key = Marker.Create(TxStore, Txid, #Legs, Keys, Terms, Fresh, Own)
	if Created == Transactions.MISMATCH then
		warn(`Ledger: transaction '{Txid}' was already used for different keys or a different amount. nothing was applied, pick a new name`)
		return { Committed = false, Why = SPENT, Again = false, Reached = Floor, Parked = Floor > 0 }
	end
	if Created == Transactions.UNWRITTEN or Key == nil then
		return { Held = Key, Committed = false, Why = UNRESOLVED, Again = true, Reached = Floor, Parked = Floor > 0 }
	end

	local Decides: string = Key
	if Minted and Clock.Now() - Carried >= LATE then
		Cleanup.Carry(TxStore, Cleanup.Mine(Home), Home, { Decides })
	end
	Stamped(Ops, Decides, Gen, Born, Print)

	if Created == Transactions.HUSK then
		return { Held = Decides, Committed = false, Why = SPENT, Again = true, Reached = Floor, Parked = Heal(TxStore, Legs, Decides, Gen, Born) > 0 }
	end

	local Prepared, Settled, Cause = PrepareAll(Legs, Ops, Floor, PerLeg)
	local Clean = Cause == nil
	assert(Settled <= #Legs, "more legs reported as already settled than the transaction has")
	assert(Prepared <= #Legs, "the transaction prepared past its own last leg")

	if Clean and Settled == #Legs then
		Marker.Decide(TxStore, Decides, Transactions.ABORTED, 0, Gen)
		return { Held = Decides, Committed = true, Why = nil, Again = false, Reached = Prepared, Parked = false }
	end

	local Split = Clean and Settled > 0
	local Aborting = not Clean or Split
	local Disown = Cause == SPENT and Minted
	local Shrink = if Aborting then (if Disown then 0 else Prepared) else nil
	local Final = Marker.Decide(TxStore, Decides, if Aborting then Transactions.ABORTED else Transactions.COMMITTED, Shrink, Gen)
	if Final == nil then
		return { Held = Decides, Committed = false, Why = UNRESOLVED, Again = true, Reached = Prepared, Parked = Prepared > 0 }
	end

	local Landed = Final == Transactions.COMMITTED
	local Verdict: Log.Verdict = { Commit = Landed, Gen = Gen, Since = Born }
	local Marks, Left = Adopted(Legs, Decides, Verdict, if Landed then #Legs else Prepared, true)
	Marker.Adopt(TxStore, Decides, Marks, Gen)
	local Stranded = Left > 0

	if Landed then
		return { Held = Decides, Committed = true, Why = nil, Again = false, Reached = Prepared, Parked = Stranded }
	end
	if not Aborting then
		return { Held = Decides, Committed = false, Why = SPENT, Again = true, Reached = Prepared, Parked = Stranded }
	end
	if Split then
		warn(`Ledger: transaction '{Txid}' had already gone through on some of its keys and not others, so Ledger cancelled it`)
		return { Held = Decides, Committed = false, Why = SPENT, Again = false, Reached = Prepared, Parked = Stranded }
	end
	return { Held = Decides, Committed = false, Why = Cause, Again = Cause == UNRESOLVED, Reached = Prepared, Parked = Stranded }
end

local function LegOp(Id: string, Index: number, Leg: Leg, Home: string): Op
	local Op: { [any]: any } = if Leg.Fields then TableUtil.DeepCopy(Leg.Fields) else {}
	if Op.Id ~= nil or Op.Kind ~= nil then
		warn(`Ledger: transaction leg '{Leg.Kind}' passed Id or Kind in its fields. those two belong to Ledger, so they got overwritten`)
	end
	Op.Id = `tx:{Id}:{Index}`
	Op.Kind = Leg.Kind

	local Fits, Unstorable = Storable.Op(Op :: Op)
	assert(Fits, `transaction leg '{Leg.Kind}' cannot be stored, {Unstorable}`)

	Op.TxHome = Home
	Op.TxSticky = Id
	return Op :: Op
end

local function Enrolled(TxStore: DataStoreWrapper, Node: string, Rolled: { string }, Added: number)
	if Clock.Now() - Added < Windows.TX then
		return
	end
	Cleanup.Carry(TxStore, Cleanup.Mine(Node), Node, Rolled)
end

local function Drive(TxStore: DataStoreWrapper, Legs: { Leg }, Id: string, Node: string?, PerLeg: number?): (boolean, Reason?, boolean)
	local Home = Node or Ids.Home()
	assert(type(Id) == "string" and #Id > 0, "a transaction needs an Id, a stable name derived from the thing being settled")
	assert(#Legs >= 2 and #Legs <= Transactions.MAX_LEGS, `a transaction takes 2 to {Transactions.MAX_LEGS} legs, got {#Legs}`)
	assert(string.sub(Id, 1, #Transactions.RESERVED) ~= Transactions.RESERVED, `a transaction Id cannot start with '{Transactions.RESERVED}', Ledger keeps that prefix for its own keys`)

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
	local Print = Digest.Of(Mark.Pack({ Keys, Shape }))

	local Added = Clock.Now()
	local Carried = Added
	local Fresh = Ids.Fresh()
	local Rolled: { string } = { Marker.KeyOf(Fresh) }
	if not Cleanup.Carry(TxStore, Cleanup.Mine(Home), Home, Rolled) then
		warn(`Ledger: transaction '{Id}' was not started, Ledger could not write it down first. nothing was applied, try again`)
		return false, UNRESOLVED, false
	end

	local Last: Reason = UNRESOLVED
	local Floor = 0
	local Parked = false
	local Own: string? = nil
	for Pass = 1, Transactions.PASSES do
		if Pass > 1 then
			Fresh = Ids.Fresh()
			local Next = Marker.KeyOf(Fresh)
			if not Cleanup.Carry(TxStore, Cleanup.Mine(Home), Home, { Next }) then
				Last = UNRESOLVED
				break
			end
			table.insert(Rolled, Next)
			Carried = Clock.Now()
		end

		local Attempt = RunOnce(TxStore, Legs, Ops, Id, Keys, Shape, Print, Floor, PerLeg, Fresh, Own, Home, Carried)
		Floor = Attempt.Reached
		Parked = Attempt.Parked
		Own = Attempt.Held or Own
		if Attempt.Committed then
			Enrolled(TxStore, Home, Rolled, Added)
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
		warn(`Ledger: transaction '{Id}' has no answer yet and might still go through. read the keys again instead of retrying it under a new name`)
	elseif Last == SPENT then
		warn(`Ledger: transaction '{Id}' could not get through and changed nothing. that name is spent now, so use a new one`)
	end

	Enrolled(TxStore, Home, Rolled, Added)
	return false, Last, Parked
end

return table.freeze({
	Drive = Drive,
})
