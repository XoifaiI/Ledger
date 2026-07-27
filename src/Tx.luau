--!strict
--!optimize 2

-- lock free multi key transactions, every leg is an op stamped so folds skip it until a marker decides the whole set

local TableUtil = require("./Util/TableUtil")
local DataStoreWrapper = require("./Util/DataStoreWrapper")
local Dedupe = require("./Dedupe")
local Log = require("./Log")
local IsStorable = require("./Storable")
local Transfer = require("./Transfer")
local Types = require("./Types")

local TIMEOUT = 60
local MAX_LEGS = 4
local PASSES = 3

local REFUSED: Types.Reason = "Refused"
local BUSY: Types.Reason = "Busy"
local SPENT: Types.Reason = "Spent"
local UNRESOLVED: Types.Reason = "Unresolved"

local CREATED = "Created"
local MISMATCH = "Mismatch"
local UNWRITTEN = "Unwritten"

type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Record<S> = Types.Record<S>
type Reducer<S> = Types.Reducer<S>
type Migration = Types.Migration
type Op = Types.Op

export type Reason = Types.Reason

local Homes: { [string]: DataStoreWrapper } = {}

export type Leg = {
	Key: string,
	Kind: string,
	Fields: { [any]: any }?,
	Log: Log.Log,
	Shape: Log.Shape<any>,
	TxStore: DataStoreWrapper
}

type Marker = {
	Status: string,
	Total: number,
	Adopted: { [string]: boolean }?,
	Keys: string?
}

local function MarkOf(Wrapper: DataStoreWrapper, Key: string): string
	return `{Wrapper.Name}\0{Key}`
end

local function AdoptedCount(Marker: Marker): number
	local Adopted = Marker.Adopted
	if type(Adopted) ~= "table" then
		return 0
	end

	local Count = 0
	for _ in Adopted do
		Count += 1
	end
	return Count
end

local function Wrap<S>(GameReducer: Reducer<S>): Reducer<S>
	local function Combined(State: S, Op: Op): S?
		local Next = GameReducer(State, Op)
		if type(Next) ~= "table" then
			return Next
		end

		local Data: any = State
		local Plain: any = Next
		local Sticky = type(Op.TxSticky) == "string"

		if not Sticky then
			local Owned = string.sub(Op.Kind, 1, 2) == "__"
			if Owned or Plain._Received ~= nil or Data._Received == nil then
				return Next
			end
		end

		local Marked = table.clone(Plain)
		Marked._Received = if Sticky
			then Transfer.Remember(Data._Received, Dedupe.Key(Dedupe.TX, Op.TxSticky), Op.TxAt)
			else Data._Received
		return Marked :: any
	end

	return Combined
end

local function CreateMarker(TxStore: DataStoreWrapper, Txid: string, Total: number, Keys: string): string
	local Clash = false
	local Ok = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) ~= "table" then
			return { Status = "Pending", Total = Total, Adopted = {}, Keys = Keys }
		end
		if type(Current.Keys) == "string" and Current.Keys ~= Keys then
			Clash = true
			return nil
		end
		return Current
	end)

	if Clash then
		return MISMATCH
	end
	return if Ok == true then CREATED else UNWRITTEN
end

local function DecideMarker(TxStore: DataStoreWrapper, Txid: string, To: string, Shrink: number?): string?
	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) ~= "table" then
			return { Status = "Aborted", Total = 0, Adopted = {} }
		end
		if Current.Status == "Pending" then
			Current.Status = To
		end
		if Shrink ~= nil and Current.Status == "Aborted" and Shrink < Current.Total then
			Current.Total = Shrink
		end
		return Current
	end)

	if not Ok or type(Value) ~= "table" then
		return nil
	end
	local Decided = Value :: Marker
	if Shrink ~= nil and Decided.Status == "Aborted" and (Decided.Total <= 0 or AdoptedCount(Decided) >= Decided.Total) then
		TxStore:RemoveAsync(Txid)
	end
	return Decided.Status
end

local function StatusOf(TxStore: DataStoreWrapper, Txid: string, Timeout: number): string?
	local Ok, Value, Info = TxStore:GetAsync(Txid)
	if not Ok then
		return nil
	end
	if type(Value) ~= "table" then
		return "Aborted"
	end

	local Marker = Value :: Marker
	if Marker.Status ~= "Pending" then
		return Marker.Status
	end

	local Updated = if Info then (Info :: DataStoreKeyInfo).UpdatedTime / 1000 else 0
	if os.time() - Updated >= Timeout then
		return DecideMarker(TxStore, Txid, "Aborted") or "Pending"
	end
	return "Pending"
end

local function Adopt(TxStore: DataStoreWrapper, Txid: string, Marks: { string })
	if #Marks == 0 then
		return
	end

	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) ~= "table" then
			return nil
		end

		local Adopted: { [string]: boolean } = if type(Current.Adopted) == "table"
			then Current.Adopted :: { [string]: boolean }
			else {}
		for _, Mark in Marks do
			Adopted[Mark] = true
		end
		Current.Adopted = Adopted
		return Current
	end)

	if not Ok or type(Value) ~= "table" then
		return
	end

	local Marker = Value :: Marker
	local Done = if Marker.Total > 0 then AdoptedCount(Marker) >= Marker.Total else Marker.Status == "Aborted"
	if Done then
		TxStore:RemoveAsync(Txid)
	end
end

local function HomeOf(TxStore: DataStoreWrapper, Home: string | true): DataStoreWrapper
	if type(Home) ~= "string" or Home == TxStore.Name then
		return TxStore
	end
	local Cached = Homes[Home]
	if not Cached then
		Cached = DataStoreWrapper.New(Home)
		Homes[Home] = Cached
	end
	return Cached
end

local function Settle(Records: Log.Log, TxStore: DataStoreWrapper, Key: string, Record: Record<any>, Timeout: number?): Record<any>
	local Limit = Timeout or TIMEOUT
	local Pending = Log.PendingTx(Record)
	if next(Pending) == nil then
		return Record
	end

	local Verdicts: { [string]: boolean } = {}
	local Markers: { [string]: DataStoreWrapper } = {}
	for Txid, Home in Pending do
		local Marker = HomeOf(TxStore, Home)
		Markers[Txid] = Marker
		local Status = StatusOf(Marker, Txid, Limit)
		if Status == "Committed" then
			Verdicts[Txid] = true
		elseif Status == "Aborted" then
			Verdicts[Txid] = false
		end
	end
	if next(Verdicts) == nil then
		return Record
	end

	local Settlement = Records:Resolve(Key, Verdicts)
	local Resolved, Counts = Settlement.Record, Settlement.Counts
	local Mark = MarkOf(Records.Wrapper, Key)
	for Txid, Count in Counts do
		if Count > 0 then
			Adopt(Markers[Txid], Txid, { Mark })
		end
	end
	return Resolved
end

local function PrepareLeg(Leg: Leg, Op: Op, Timeout: number?): string
	local Record = Settle(Leg.Log, Leg.TxStore, Leg.Key, Leg.Log:Read(Leg.Key), Timeout)
	if Log.HasPending(Record) then
		return Log.Verdict.Busy
	end
	return Leg.Log:Prepare(Leg.Key, Op, Leg.Shape)
end

local function RunOnce(
	TxStore: DataStoreWrapper,
	Legs: { Leg },
	Ops: { Op },
	Txid: string,
	Keys: string,
	Timeout: number?
): (boolean, Reason?, boolean)
	local Created = CreateMarker(TxStore, Txid, #Legs, Keys)
	if Created == MISMATCH then
		warn(`Ledger: transaction '{Txid}' already named a different set of keys, a transaction name must always mean the same set`)
		return false, SPENT, false
	end
	if Created == UNWRITTEN then
		return false, UNRESOLVED, true
	end

	local Prepared = 0
	local Settled = 0
	local Cause: Reason? = nil

	for Index, Leg in Legs do
		local Fine, Verdict = pcall(PrepareLeg, Leg, Ops[Index], Timeout)

		if not Fine then
			Cause = UNRESOLVED
			break
		elseif Verdict == Log.Verdict.Settled then
			Settled += 1
			Prepared = Index
		elseif Verdict == Log.Verdict.Prepared then
			Prepared = Index
		elseif Verdict == Log.Verdict.Busy then
			Cause = BUSY
			break
		else
			Cause = REFUSED
			break
		end
	end

	if Cause == nil and Settled == #Legs then
		DecideMarker(TxStore, Txid, "Aborted", 0)
		return true, nil, false
	end

	local Split = Cause == nil and Settled > 0
	if Split then
		Cause = SPENT
	end

	local Failed = Cause ~= nil
	local Final = DecideMarker(TxStore, Txid, if Failed then "Aborted" else "Committed", if Failed then Prepared else nil)
	if Final == nil and not Failed then
		return false, UNRESOLVED, true
	end

	local Committed = Final == "Committed"
	local Adopting: { string } = {}
	for Index = 1, if Failed then Prepared else #Legs do
		local Leg = Legs[Index]
		local Ok, Settlement = pcall(function()
			return Leg.Log:Resolve(Leg.Key, { [Txid] = Committed })
		end)
		if Ok and Settlement.Counts[Txid] then
			table.insert(Adopting, MarkOf(Leg.Log.Wrapper, Leg.Key))
		end
	end
	Adopt(TxStore, Txid, Adopting)

	if not Failed and not Committed then
		return false, SPENT, true
	end

	if Committed then
		return true, nil, false
	end

	if Split then
		warn(`Ledger: transaction '{Txid}' is only half remembered across its keys, so it is being cancelled rather than applied to some of them`)
	end
	return false, Cause, Cause == UNRESOLVED
end

local function Drive(TxStore: DataStoreWrapper, Legs: { Leg }, Id: string, Timeout: number?): (boolean, Reason?)
	assert(type(Id) == "string" and #Id > 0, "a transaction needs an Id, a stable name derived from the thing being settled")
	assert(#Legs >= 2 and #Legs <= MAX_LEGS, `a transaction takes 2 to {MAX_LEGS} legs, got {#Legs}`)

	local Marks: { string } = table.create(#Legs) :: { string }
	local Touched: { [string]: boolean } = {}
	for Index, Leg in Legs do
		local Mark = MarkOf(Leg.Log.Wrapper, Leg.Key)
		assert(not Touched[Mark], `a transaction may only touch a key once per store, '{Leg.Key}' appears twice`)
		Touched[Mark] = true
		Marks[Index] = Mark
	end
	local Keys = table.concat(Marks, "\1")

	local Now = os.time()
	local Ops: { Op } = table.create(#Legs) :: { Op }
	for Index, Leg in Legs do
		local Op: { [any]: any } = if Leg.Fields then TableUtil.DeepCopy(Leg.Fields) else {}
		if Op.Id ~= nil or Op.Kind ~= nil then
			warn(`Ledger: transaction leg '{Leg.Kind}' fields carried Id or Kind, those are reserved and were overwritten`)
		end
		Op.Id = `tx:{Id}:{Index}`
		Op.Kind = Leg.Kind

		local Storable, Unstorable = IsStorable.Op(Op :: Op)
		assert(Storable, `transaction leg '{Leg.Kind}' cannot be stored, {Unstorable}`)

		Op.Tx = Id
		Op.TxHome = TxStore.Name
		Op.TxSticky = Id
		Op.TxAt = Now
		Ops[Index] = Op :: Op
	end

	local Last: Reason = UNRESOLVED
	for _ = 1, PASSES do
		local Committed, Why, Again = RunOnce(TxStore, Legs, Ops, Id, Keys, Timeout)
		if Committed then
			return true, nil
		end

		if Why ~= nil then
			Last = Why
		end
		if not Again then
			break
		end
	end

	if Last == UNRESOLVED then
		warn(`Ledger: transaction '{Id}' has no answer yet and may still go through. read the keys again rather than running it under a new name`)
	elseif Last == SPENT then
		warn(`Ledger: transaction '{Id}' could not get through and changed nothing. that name cannot be used again, so use a new one`)
	end
	return false, Last
end

local function ShutdownHomes(Attempts: number)
	for _, Wrapper in Homes do
		Wrapper:SkipAllQueuesToLastEnqueued()
		Wrapper.Attempts = Attempts
	end
end

return table.freeze({
	Wrap = Wrap,
	Drive = Drive,
	Settle = Settle,
	ShutdownHomes = ShutdownHomes,
	TIMEOUT = TIMEOUT,
	MAX_LEGS = MAX_LEGS
})
