--!strict
--!optimize 2

-- lock free multi key transactions, every leg is an op stamped so folds skip it until a marker decides the whole set. legs are prepared one after another, so how long a coordinator may take before a bystander calls it dead is per leg times the leg count the marker already carries

local TableUtil = require("./Util/TableUtil")
local Clock = require("./Clock")
local DataStoreWrapper = require("./Util/DataStoreWrapper")
local Fault = require("./Fault")
local Dedupe = require("./Record/Dedupe")
local Fingerprint = require("./Record/Fingerprint")
local Ident = require("./Record/Ident")
local Log = require("./Record/Log")
local Mark = require("./Mark")
local Reasons = require("./Reason")
local IsStorable = require("./Record/Storable")
local Transfer = require("./Transfer")
local Types = require("./Types")

local LEG_TIMEOUT = 30
local TIMEOUT = LEG_TIMEOUT * 2
local MAX_LEGS = 4
local PASSES = 3
local REAP_HORIZON = 3600
local REAP_LIMIT = 64

local REFUSED = Reasons.Refused
local BUSY = Reasons.Busy
local SPENT = Reasons.Spent
local UNRESOLVED = Reasons.Unresolved

local CREATED: Outcome = "Created"
local MISMATCH: Outcome = "Mismatch"
local UNWRITTEN: Outcome = "Unwritten"
local HUSK: Outcome = "Husk"

local PENDING: Status = "Pending"
local COMMITTED: Status = "Committed"
local ABORTED: Status = "Aborted"

type Status = "Pending" | "Committed" | "Aborted"
type Outcome = "Created" | "Mismatch" | "Unwritten" | "Husk"

type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Record<S> = Types.Record<S>
type Reducer<S> = Types.Reducer<S>
type Migration = Types.Migration
type Op = Types.Op

export type Reason = Types.Reason

type Lookup = (Name: string) -> Log.Log?

type Pass = {
	read Committed: boolean,
	read Why: Reason?,
	read Again: boolean,
	read Reached: number
}

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
	Status: Status,
	Total: number,
	Gen: string?,
	At: number?,
	Adopted: { [string]: boolean }?,
	Keys: string?,
	Terms: string?
}

local Canon = Fingerprint.Canon

local function GenOf(Value: any): string?
	if type(Value) ~= "table" or type(Value.Gen) ~= "string" then
		return nil
	end
	return Value.Gen
end

local function BornAt(Value: any, Fallback: number): number
	if type(Value) ~= "table" or type(Value.At) ~= "number" then
		return Fallback
	end
	return Value.At
end

local function MarkOf(Wrapper: DataStoreWrapper, Key: string): string
	return Mark.Of(Wrapper.Name, Key)
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

local function StampOf(Op: Op): (string?, any, string?)
	if type(Op.TxSticky) == "string" then
		return Dedupe.Key(Dedupe.TX, Op.TxSticky), Op.TxAt, Op.TxTerms
	end
	if type(Op.Once) == "string" then
		return Dedupe.Key(Dedupe.ONCE, Op.Once), Op.OnceAt, nil
	end
	return nil, nil, nil
end

local function Wrap<S>(GameReducer: Reducer<S>): Reducer<S>
	local function Combined(State: S, Op: Op): S?
		local Data: any = State
		if type(Op.Once) == "string" and Dedupe.Has(Data._Received, Dedupe.ONCE, Op.Once) then
			return nil
		end

		local Next = GameReducer(State, Op)
		if type(Next) ~= "table" then
			return Next
		end
		local Plain: any = Next

		local Stamp, At, Print = StampOf(Op)
		if Stamp ~= nil then
			local Marked = table.clone(Plain)
			Marked._Received = Transfer.Remember(Data._Received, Stamp, At, Print)

			if (Marked._Received :: any)[Stamp] == nil then
				Fault.Broke(`op '{tostring(Op.Kind)}' applied under a name that was not written down, so it could apply again`)
				return nil
			end
			return Marked :: any
		end

		local Touched = Data._Received ~= nil
			and Plain._Received ~= Data._Received
			and not IsStorable.Reserved(Op.Kind)
		if not Touched then
			return Next
		end

		if Plain._Received ~= nil then
			Fault.Broke(`your reducer wrote its own _Received on op '{tostring(Op.Kind)}', so Ledger put the applied names back`)
		end

		local Kept = table.clone(Plain)
		Kept._Received = Data._Received
		return Kept :: any
	end

	return Combined
end

local function CreateMarker(
	TxStore: DataStoreWrapper,
	Txid: string,
	Total: number,
	Keys: string,
	Terms: string
): (Outcome, string?, number, boolean)
	assert(Total > 0, "a transaction marker is being opened for no legs at all")

	local Clash = false
	local Minted = false
	local Born = Clock.Now()
	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		Clash = false
		Minted = false
		if type(Current) ~= "table" then
			Minted = true
			return {
				Status = PENDING,
				Total = Total,
				Gen = Ident.Fresh(),
				At = Born,
				Adopted = {},
				Keys = Keys,
				Terms = Terms
			}
		end
		if type(Current.Keys) == "string" and Current.Keys ~= Keys then
			Clash = true
			return nil
		end
		if type(Current.Terms) == "string" and Current.Terms ~= Terms then
			Clash = true
			return nil
		end

		return Current
	end)

	if Clash then
		return MISMATCH, nil, Born, false
	end
	if Ok ~= true then
		return UNWRITTEN, nil, Born, false
	end
	if type(Value) == "table" and (Value :: Marker).Status == ABORTED then
		return HUSK, GenOf(Value), BornAt(Value, Born), Minted
	end
	return CREATED, GenOf(Value), BornAt(Value, Born), Minted
end

local function DecideMarker(TxStore: DataStoreWrapper, Txid: string, To: Status, Shrink: number?): Status?
	assert(To ~= PENDING, "a transaction is being decided back to pending, which would let it start over")

	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) ~= "table" then
			return nil
		end
		if Current.Status == PENDING then
			Current.Status = To
		end
		if Shrink ~= nil and Current.Status == ABORTED and Shrink < Current.Total then
			Current.Total = Shrink
		end
		return Current
	end)

	if not Ok or type(Value) ~= "table" then
		return nil
	end
	local Decided = Value :: Marker
	Fault.Holds(
		Decided.Status ~= PENDING,
		`transaction '{Txid}' was decided but its marker is still pending, so another server could decide it the other way`
	)

	if Shrink ~= nil and Decided.Status == ABORTED and (Decided.Total <= 0 or AdoptedCount(Decided) >= Decided.Total) then
		TxStore:RemoveAsync(Txid)
	end
	return Decided.Status
end

local function StatusOf(TxStore: DataStoreWrapper, Txid: string, PerLeg: number): (Status?, string?, number)
	local Looked = Clock.Now()
	local Ok, Value, Info = TxStore:GetAsync(Txid)
	if not Ok then
		return nil, nil, Looked
	end
	if type(Value) ~= "table" then
		return ABORTED, nil, Looked
	end

	local Marker = Value :: Marker
	local Gen, Born = GenOf(Value), BornAt(Value, 0)
	if Marker.Status ~= PENDING then
		return Marker.Status, Gen, Born
	end

	local Legs = if type(Marker.Total) == "number" and Marker.Total > 0 then Marker.Total else MAX_LEGS
	local Updated = if Info then (Info :: DataStoreKeyInfo).UpdatedTime / 1000 else 0
	if Clock.Now() - Updated >= PerLeg * Legs then
		return DecideMarker(TxStore, Txid, ABORTED) or PENDING, Gen, Born
	end
	return PENDING, Gen, Born
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
	local Done = if Marker.Total > 0 then AdoptedCount(Marker) >= Marker.Total else Marker.Status == ABORTED
	if Done then
		Fault.Holds(
			Marker.Status ~= PENDING,
			`transaction '{Txid}' is having its marker taken away while it is still undecided, so a retry would run it again`
		)
		TxStore:RemoveAsync(Txid)
	end
end

local function Spent(Record: Record<any>, Txid: string, Gen: string?, Born: number): boolean
	if type(Gen) ~= "string" then
		return false
	end

	for _, Op in Record.Ops do
		if Op.Tx ~= Txid then
			continue
		end

		local Mine = Op.TxGen
		if type(Mine) ~= "string" or Mine == Gen then
			return false
		end
		if type(Op.TxAt) ~= "number" or Op.TxAt >= Born then
			return false
		end
	end
	return true
end

local function Quiet(Txid: string, Keys: any, Lookup: Lookup, Gen: string?, Born: number): boolean
	if type(Keys) ~= "string" or #Keys == 0 then
		return false
	end

	for _, Held in Mark.Unpack(Keys) do
		local Store, Key = Mark.Split(Held)
		if Store == nil or Key == nil then
			return false
		end

		local Records = Lookup(Store)
		if Records == nil then
			return false
		end

		local Read, Record = pcall(function(): Record<any>
			return Records:Read(Key :: string)
		end)
		if not Read or not Spent(Record, Txid, Gen, Born) then
			return false
		end
	end

	return true
end

local function Reap(TxStore: DataStoreWrapper, Lookup: Lookup, Horizon: number?, Limit: number?): number
	local Ok, Pages = TxStore:ListKeysAsync("", Limit or REAP_LIMIT)
	if not Ok then
		error(Pages)
	end

	local Older = Horizon or REAP_HORIZON
	local Now = Clock.Now()
	local Reaped = 0

	for _, Entry in (Pages :: DataStoreKeyPages):GetCurrentPage() do
		local Txid = (Entry :: any).KeyName
		local Read, Value, Info = TxStore:GetAsync(Txid)
		if not Read or type(Value) ~= "table" then
			continue
		end

		local Marker = Value :: Marker
		local Updated = if Info then (Info :: DataStoreKeyInfo).UpdatedTime / 1000 else 0
		if Now - Updated < Older then
			continue
		end

		if Marker.Status ~= ABORTED and not Quiet(Txid, Marker.Keys, Lookup, GenOf(Value), BornAt(Value, 0)) then
			continue
		end

		if (TxStore:RemoveAsync(Txid)) then
			Reaped += 1
		end
	end

	return Reaped
end

local function Elsewhere(Name: string): DataStoreWrapper
	local Cached = Homes[Name]
	if Cached == nil then
		Cached = DataStoreWrapper.New(Name)
		Homes[Name] = Cached
	end
	return Cached
end

local function HomeOf(TxStore: DataStoreWrapper, Home: string | true): DataStoreWrapper
	if Home == true or Home == TxStore.Name then
		return TxStore
	end

	return Elsewhere(Home)
end

local function Settle(Records: Log.Log, TxStore: DataStoreWrapper, Key: string, Record: Record<any>, PerLeg: number?): Record<any>
	local Limit = PerLeg or LEG_TIMEOUT
	local Pending = Log.PendingTx(Record)
	if next(Pending) == nil then
		return Record
	end

	local Verdicts: { [string]: Log.Verdict } = {}
	local Markers: { [string]: DataStoreWrapper } = {}
	for Txid, Home in Pending do
		local Marker = HomeOf(TxStore, Home)
		Markers[Txid] = Marker
		local Status, Gen, Since = StatusOf(Marker, Txid, Limit)
		if Status == COMMITTED then
			Verdicts[Txid] = { Commit = true, Gen = Gen, Since = Since }
		elseif Status == ABORTED then
			Verdicts[Txid] = { Commit = false, Gen = Gen, Since = Since }
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
			local Marker = Markers[Txid]
			assert(Marker ~= nil, `settled a leg for transaction '{Txid}' whose marker was never read`)
			Adopt(Marker, Txid, { Mark })
		end
	end
	return Resolved
end

local function PrepareLeg(Leg: Leg, Op: Op, PerLeg: number?): Log.Prepared
	local Record = Settle(Leg.Log, Leg.TxStore, Leg.Key, Leg.Log:Read(Leg.Key), PerLeg)

	local Already = Log.Known(Record, Op, Leg.Shape)
	if Already ~= nil then
		return Already
	end
	if Log.HasPending(Record) then
		return Log.Verdict.Busy
	end

	return Leg.Log:Prepare(Leg.Key, Op, Leg.Shape)
end

local function Stamp(Ops: { Op }, Gen: string?, Born: number, Print: string)
	for _, Op in Ops do
		Op.TxGen = Gen
		Op.TxAt = Born
		Op.TxTerms = Print
	end
end

local function Adopted(Legs: { Leg }, Txid: string, Verdict: Log.Verdict, Upto: number, Tidy: boolean): { string }
	Fault.Holds(Upto <= #Legs, `transaction '{Txid}' is resolving more legs than it has`)
	Fault.Holds(not Verdict.Commit or Upto == #Legs, `transaction '{Txid}' is committing without resolving every one of its legs`)

	local Marks: { string } = {}
	for Index = 1, Upto do
		local Leg = Legs[Index]
		local Ok, Settlement = pcall(function()
			return Leg.Log:Resolve(Leg.Key, { [Txid] = Verdict })
		end)
		if Ok and Settlement.Counts[Txid] then
			table.insert(Marks, MarkOf(Leg.Log.Wrapper, Leg.Key))
			if Tidy then
				Leg.Log:Trim(Leg.Key, Leg.Shape, Settlement.Record)
			end
		end
	end
	return Marks
end

local function Heal(TxStore: DataStoreWrapper, Legs: { Leg }, Txid: string, Gen: string?, Born: number)
	local Verdict: Log.Verdict = { Commit = false, Gen = Gen, Since = Born }
	Adopt(TxStore, Txid, Adopted(Legs, Txid, Verdict, #Legs, false))
	DecideMarker(TxStore, Txid, ABORTED, 0)
end

local function PrepareAll(Legs: { Leg }, Ops: { Op }, Floor: number, PerLeg: number?): (number, number, Reason?)
	local Prepared = Floor
	local Settled = 0

	for Index, Leg in Legs do
		local Fine, Verdict = pcall(PrepareLeg, Leg, Ops[Index], PerLeg)

		if not Fine then
			return Prepared, Settled, UNRESOLVED
		elseif Verdict == Log.Verdict.Settled then
			Settled += 1
			Prepared = math.max(Prepared, Index)
		elseif Verdict == Log.Verdict.Prepared then
			Prepared = math.max(Prepared, Index)
		elseif Verdict == Log.Verdict.Busy then
			return Prepared, Settled, BUSY
		elseif Verdict == Log.Verdict.Spent then
			warn(
				`Ledger: transaction '{Ops[Index].Tx}' was already used for different keys or a different amount, and a name has to mean the same thing every time. nothing was applied, so pick a new name`
			)
			return Prepared, Settled, SPENT
		else
			return Prepared, Settled, REFUSED
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
	PerLeg: number?
): Pass
	local Created, Gen, Born, Minted = CreateMarker(TxStore, Txid, #Legs, Keys, Terms)
	if Created == MISMATCH then
		warn(
			`Ledger: transaction '{Txid}' was already used for different keys or a different amount, and a name has to mean the same thing every time. nothing was applied, so pick a new name`
		)
		return { Committed = false, Why = SPENT, Again = false, Reached = Floor }
	end
	if Created == UNWRITTEN then
		return { Committed = false, Why = UNRESOLVED, Again = true, Reached = Floor }
	end

	Stamp(Ops, Gen, Born, Print)

	if Created == HUSK then
		Heal(TxStore, Legs, Txid, Gen, Born)
		return { Committed = false, Why = SPENT, Again = true, Reached = Floor }
	end

	local Prepared, Settled, Cause = PrepareAll(Legs, Ops, Floor, PerLeg)
	local Clean = Cause == nil
	assert(Settled <= #Legs, "more legs reported as already settled than the transaction has")
	assert(Prepared <= #Legs, "the transaction prepared past its own last leg")

	if Clean and Settled == #Legs then
		DecideMarker(TxStore, Txid, ABORTED, 0)
		return { Committed = true, Why = nil, Again = false, Reached = Prepared }
	end

	local Split = Clean and Settled > 0
	local Aborting = not Clean or Split
	local Disown = Cause == SPENT and Minted
	local Shrink = if Aborting then (if Disown then 0 else Prepared) else nil
	local Final = DecideMarker(TxStore, Txid, if Aborting then ABORTED else COMMITTED, Shrink)
	if Final == nil then
		return { Committed = false, Why = UNRESOLVED, Again = true, Reached = Prepared }
	end

	local Landed = Final == COMMITTED
	local Verdict: Log.Verdict = { Commit = Landed, Gen = Gen, Since = Born }
	Adopt(TxStore, Txid, Adopted(Legs, Txid, Verdict, if Aborting then Prepared else #Legs, true))

	if Landed then
		return { Committed = true, Why = nil, Again = false, Reached = Prepared }
	end
	if not Aborting then
		return { Committed = false, Why = SPENT, Again = true, Reached = Prepared }
	end
	if Split then
		warn(`Ledger: transaction '{Txid}' is only half remembered across its keys, so Ledger cancelled it rather than applying it to some keys and not others`)
		return { Committed = false, Why = SPENT, Again = false, Reached = Prepared }
	end
	return { Committed = false, Why = Cause, Again = Cause == UNRESOLVED, Reached = Prepared }
end

local function LegOp(Id: string, Index: number, Leg: Leg, Home: string): Op
	local Op: { [any]: any } = if Leg.Fields then TableUtil.DeepCopy(Leg.Fields) else {}
	if Op.Id ~= nil or Op.Kind ~= nil then
		warn(`Ledger: transaction leg '{Leg.Kind}' passed Id or Kind in its fields. those two belong to Ledger, so they got overwritten`)
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

local function Drive(TxStore: DataStoreWrapper, Legs: { Leg }, Id: string, PerLeg: number?): (boolean, Reason?)
	assert(type(Id) == "string" and #Id > 0, "a transaction needs an Id, a stable name derived from the thing being settled")
	assert(#Legs >= 2 and #Legs <= MAX_LEGS, `a transaction takes 2 to {MAX_LEGS} legs, got {#Legs}`)

	local Marks: { string } = {}
	local Terms: { string } = {}
	local Ops: { Op } = {}
	local Touched: { [string]: boolean } = {}

	for Index, Leg in Legs do
		local Mark = MarkOf(Leg.Log.Wrapper, Leg.Key)
		assert(not Touched[Mark], `a transaction may only touch a key once per store, '{Leg.Key}' appears twice`)
		Touched[Mark] = true

		Marks[Index] = Mark
		Terms[Index] = `{Leg.Kind}{Canon(Leg.Fields)}`
		Ops[Index] = LegOp(Id, Index, Leg, TxStore.Name)
	end

	local Keys = Mark.Pack(Marks)
	local Shape = Mark.Pack(Terms)
	local Print = Fingerprint.Of(Mark.Pack({ Keys, Shape }))

	local Last: Reason = UNRESOLVED
	local Floor = 0
	for _ = 1, PASSES do
		local Attempt = RunOnce(TxStore, Legs, Ops, Id, Keys, Shape, Print, Floor, PerLeg)
		Floor = Attempt.Reached
		if Attempt.Committed then
			return true, nil
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
	Reap = Reap,
	ShutdownHomes = ShutdownHomes,
	LEG_TIMEOUT = LEG_TIMEOUT,
	TIMEOUT = TIMEOUT,
	MAX_LEGS = MAX_LEGS,
	REAP_HORIZON = REAP_HORIZON
})
