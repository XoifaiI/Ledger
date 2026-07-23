--!strict
--!optimize 2

--[=[
    Tx: lock-free multi key transactions over the op log. every leg is a normal op stamped
    with a Tx marker that folds skip, so a prepared leg has not happened yet; a marker in a
    side store decides the whole set at once, committed strips the stamps and aborted removes
    the legs and retires their ids. the log is append only, so a leg accepted at prepare is
    still accepted when the stamp comes off. one pending transaction per key.

    crashes resolve themselves: any server that hits a pending leg settles it from the marker,
    a marker still Pending past the timeout aborts, and an adoption counter cleans it up. a
    failed decision write is treated as unknown, not aborted, so a lost ack can delay a commit
    but never split it. legs may live on different datastores, each carrying its own runtime;
    the marker stays in the coordinator's store, stamped onto every leg as TxHome so any
    bystander can find it. see docs/transactions.md for the full rules.

    Return type: frozen table { Drive, Settle, TIMEOUT }
    Example usage:
        local Committed = Tx.Drive(Wrapper, TxStore, Reducer, Initial, Migrations, Legs)
--]=]

local HttpService = game:GetService("HttpService")

local TableUtil = require("./Util/TableUtil")
local DataStoreWrapper = require("./Util/DataStoreWrapper")
local Log = require("./Log")
local IsStorable = require("./Storable")
local Types = require("./Types")

local TIMEOUT = 60
local MAX_LEGS = 4

type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Record<S> = Types.Record<S>
type Reducer<S> = Types.Reducer<S>
type Migration = Types.Migration
type Op = Types.Op

local Homes: { [string]: DataStoreWrapper } = {}

export type Leg = {
	Key: string,
	Kind: string,
	Fields: { [any]: any }?,
	Wrapper: DataStoreWrapper?,
	TxStore: DataStoreWrapper?,
	Reducer: Reducer<any>?,
	Initial: any?,
	Migrations: { Migration }?,
}

type Marker = {
	Status: string,
	Total: number,
	Adopted: number,
}

local function CreateMarker(TxStore: DataStoreWrapper, Txid: string, Total: number): boolean
	local Ok = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) == "table" then
			return Current
		end
		return { Status = "Pending", Total = Total, Adopted = 0 }
	end)
	return Ok == true
end

local function DecideMarker(TxStore: DataStoreWrapper, Txid: string, To: string, Shrink: number?): string?
	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) ~= "table" then
			return { Status = "Aborted", Total = 0, Adopted = 0 }
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
	if Shrink ~= nil and Decided.Status == "Aborted" and (Decided.Total <= 0 or Decided.Adopted >= Decided.Total) then
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

local function Adopt(TxStore: DataStoreWrapper, Txid: string, Count: number)
	if Count <= 0 then
		return
	end

	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) ~= "table" then
			return nil
		end
		Current.Adopted += Count
		return Current
	end)

	if Ok and type(Value) == "table" and Value.Total > 0 and Value.Adopted >= Value.Total then
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

local function Settle(Wrapper: DataStoreWrapper, TxStore: DataStoreWrapper, Key: string, Record: Record<any>, Timeout: number?): Record<any>
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

	local Resolved, Counts = Log.Resolve(Wrapper, Key, Verdicts)
	for Txid, Count in Counts do
		Adopt(Markers[Txid], Txid, Count)
	end
	return Resolved
end

local function PrepareLeg(
	Wrapper: DataStoreWrapper,
	TxStore: DataStoreWrapper,
	Reducer: Reducer<any>,
	Initial: any,
	Migrations: { Migration }?,
	Key: string,
	Op: Op,
	Timeout: number?
): string
	local Record = Log.Read(Wrapper, Key)
	Record = Settle(Wrapper, TxStore, Key, Record, Timeout)
	if Log.HasPending(Record) then
		return "Busy"
	end
	return Log.Prepare(Wrapper, Key, Op, Reducer, Initial, Migrations)
end

local function Drive(
	Wrapper: DataStoreWrapper,
	TxStore: DataStoreWrapper,
	Reducer: Reducer<any>,
	Initial: any,
	Migrations: { Migration }?,
	Legs: { Leg },
	Timeout: number?
): boolean
	if #Legs < 2 or #Legs > MAX_LEGS then
		warn(`Ledger: rejected transaction, it takes 2 to {MAX_LEGS} legs`)
		return false
	end

	local Keys: { [string]: boolean } = {}
	for _, Leg in Legs do
		local Mark = `{(Leg.Wrapper or Wrapper).Name}\0{Leg.Key}`
		if Keys[Mark] then
			warn("Ledger: rejected transaction, it may only touch a key once per store")
			return false
		end
		Keys[Mark] = true
	end

	local Txid = HttpService:GenerateGUID(false)
	local Ops: { Op } = {}
	for Index, Leg in Legs do
		local Op: { [any]: any } = if Leg.Fields then TableUtil.DeepCopy(Leg.Fields) else {}
		if Op.Id ~= nil or Op.Kind ~= nil then
			warn(`Ledger: transaction leg '{Leg.Kind}' fields carried Id or Kind, those are reserved and were overwritten`)
		end
		Op.Id = `tx:{Txid}:{Index}`
		Op.Kind = Leg.Kind

		local Storable, Reason = IsStorable.Op(Op)
		if not Storable then
			warn(`Ledger: rejected transaction leg '{Leg.Kind}', {Reason}`)
			return false
		end

		Op.Tx = Txid
		Op.TxHome = TxStore.Name
		Ops[Index] = Op :: Op
	end

	if not CreateMarker(TxStore, Txid, #Legs) then
		return false
	end

	local Prepared = 0
	local Failed = false
	for Index, Leg in Legs do
		local Fine, Verdict = pcall(
			PrepareLeg,
			Leg.Wrapper or Wrapper,
			Leg.TxStore or TxStore,
			if Leg.Wrapper then Leg.Reducer :: Reducer<any> else Reducer,
			if Leg.Wrapper then Leg.Initial else Initial,
			if Leg.Wrapper then Leg.Migrations else Migrations,
			Leg.Key,
			Ops[Index],
			Timeout
		)

		if Fine and Verdict == "Prepared" then
			Prepared = Index
		else
			Failed = true
			break
		end
	end

	local Final = DecideMarker(TxStore, Txid, if Failed then "Aborted" else "Committed", if Failed then Prepared else nil)
	if Final == nil and not Failed then
		warn(`Ledger: transaction {Txid} could not record its verdict, its legs stay pending until another server settles them from the marker`)
		return false
	end

	for Index = 1, if Failed then Prepared else #Legs do
		local Leg = Legs[Index]
		local Ok, _, Counts = pcall(Log.Resolve, Leg.Wrapper or Wrapper, Leg.Key, { [Txid] = Final == "Committed" })
		if Ok then
			for Id, Count in Counts :: { [string]: number } do
				Adopt(TxStore, Id, Count)
			end
		end
	end

	return Final == "Committed"
end

local function ShutdownHomes(Attempts: number)
	for _, Wrapper in Homes do
		Wrapper:SkipAllQueuesToLastEnqueued()
		Wrapper.Attempts = Attempts
	end
end

return table.freeze({
	Drive = Drive,
	Settle = Settle,
	ShutdownHomes = ShutdownHomes,
	TIMEOUT = TIMEOUT,
})
