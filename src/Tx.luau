--!strict
--!optimize 2

--[=[
    Tx: multi key transactions over the op log, no locks. every leg is a normal op
    stamped with a Tx marker, and folds skip stamped ops, so a prepared leg has not
    happened yet. a marker record in a side store decides the whole set at once:
    committed strips the stamps and the legs become ordinary ops, aborted removes them
    and retires their ids so a retry cannot bring them back.

    the trick that makes it safe is that the log is append only. a leg's position is
    fixed the moment it is prepared, nothing can ever be inserted before it, so a leg
    the reducer accepted at prepare is still accepted when the stamp comes off.

    crashes are someone else's problem, literally: any server that runs into a pending
    leg resolves it from the marker, and whoever finds a marker still Pending past the
    timeout aborts it. an adoption counter cleans the marker up once every leg is done.
    one pending transaction per key at a time; a second one answers Busy and aborts.

    Return type: frozen table { Drive, Settle, TIMEOUT }
    Example usage:
        local Tx = require("./Tx")
        local Committed = Tx.Drive(Wrapper, TxStore, Reducer, Initial, Migrations, {
            { Key = "261", Kind = "Delta", Fields = { Gold = 25, Drop = "Sword" } },
            { Key = "262", Kind = "Delta", Fields = { Gold = -25, Gain = "Sword" } },
        })
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

export type Leg = {
	Key: string,
	Kind: string,
	Fields: { [any]: any }?,
}

type Marker = {
	Status: string,
	Total: number,
	Adopted: number,
}

local function CreateMarker(TxStore: DataStoreWrapper, Txid: string, Total: number)
	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) == "table" then
			return Current
		end
		return { Status = "Pending", Total = Total, Adopted = 0 }
	end)
	if not Ok then
		error(Value)
	end
end

local function DecideMarker(TxStore: DataStoreWrapper, Txid: string, To: string): string
	local Ok, Value = TxStore:UpdateAsync(Txid, function(Current: any): Marker?
		if type(Current) ~= "table" then
			return { Status = "Aborted", Total = 0, Adopted = 0 }
		end
		if Current.Status == "Pending" then
			Current.Status = To
		end
		return Current
	end)

	if not Ok or type(Value) ~= "table" then
		return "Aborted"
	end
	return Value.Status
end

local function StatusOf(TxStore: DataStoreWrapper, Txid: string, Timeout: number): string
	local Ok, Value, Info = TxStore:GetAsync(Txid)
	if not Ok then
		error(Value)
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
		return DecideMarker(TxStore, Txid, "Aborted")
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

local function Settle(Wrapper: DataStoreWrapper, TxStore: DataStoreWrapper, Key: string, Record: Record<any>, Timeout: number?): Record<any>
	local Limit = Timeout or TIMEOUT
	local Pending = Log.PendingTx(Record)
	if next(Pending) == nil then
		return Record
	end

	local Verdicts: { [string]: boolean } = {}
	for Txid in Pending do
		local Ok, Status = pcall(StatusOf, TxStore, Txid, Limit)
		if Ok and Status == "Committed" then
			Verdicts[Txid] = true
		elseif Ok and Status == "Aborted" then
			Verdicts[Txid] = false
		end
	end
	if next(Verdicts) == nil then
		return Record
	end

	local Resolved, Counts = Log.Resolve(Wrapper, Key, Verdicts)
	for Txid, Count in Counts do
		pcall(Adopt, TxStore, Txid, Count)
	end
	return Resolved
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
		if Keys[Leg.Key] then
			warn("Ledger: rejected transaction, it may only touch a key once")
			return false
		end
		Keys[Leg.Key] = true
	end

	local Txid = HttpService:GenerateGUID(false)
	local Ops: { Op } = {}
	for Index, Leg in Legs do
		local Op: { [any]: any } = if Leg.Fields then TableUtil.DeepCopy(Leg.Fields) else {}
		Op.Id = `tx:{Txid}:{Index}`
		Op.Kind = Leg.Kind

		local Storable, Reason = IsStorable.Op(Op)
		if not Storable then
			warn(`Ledger: rejected transaction leg '{Leg.Kind}', {Reason}`)
			return false
		end

		Op.Tx = Txid
		Ops[Index] = Op :: Op
	end

	local Created = pcall(CreateMarker, TxStore, Txid, #Legs)
	if not Created then
		return false
	end

	local Prepared = 0
	local Failed = false
	for Index, Leg in Legs do
		local Fine, Verdict = pcall(function(): string
			local Record = Log.Read(Wrapper, Leg.Key)
			Record = Settle(Wrapper, TxStore, Leg.Key, Record, Timeout)
			if Log.HasPending(Record) then
				return "Busy"
			end
			return Log.Prepare(Wrapper, Leg.Key, Ops[Index], Reducer, Initial, Migrations)
		end)

		if Fine and Verdict == "Prepared" then
			Prepared = Index
		else
			Failed = true
			break
		end
	end

	local Final = DecideMarker(TxStore, Txid, if Failed then "Aborted" else "Committed")

	for Index = 1, if Failed then Prepared else #Legs do
		pcall(function()
			local _, Counts = Log.Resolve(Wrapper, Legs[Index].Key, { [Txid] = Final == "Committed" })
			for Id, Count in Counts do
				Adopt(TxStore, Id, Count)
			end
		end)
	end

	return Final == "Committed"
end

return table.freeze({
	Drive = Drive,
	Settle = Settle,
	TIMEOUT = TIMEOUT,
})
