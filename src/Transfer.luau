--!strict
--!optimize 2

--[=[
    Transfer: move a balance across two keys in three legs, reserve on the sender, deliver
    to the receiver, settle the hold. each leg is single-key atomic and deduped by transfer
    id, and the held bookkeeping rides across game ops so an unrelated edit cannot drop it.
    money is never minted, lost, or double-spent, and held money is unspendable.

    a crash mid-transfer resolves on the sender's next load or via Recover. within the
    redrive horizon it re-drives; past it the hold settles if the deliver landed or refunds
    if it did not, safe because nothing delivers that late. each deliver prunes delivered
    ids past the prune horizon so the set stays bounded. see docs/cross-server.md for the
    horizon reasoning and the one accepted corner.

    Return type: frozen table { Wrap, Reserve, Post, Prune, Drive, Recover }
    Example usage:
        local Ok = Transfer.Drive(Store, Reducer, Initial, From, To, Amount)
--]=]

local HttpService = game:GetService("HttpService")

local DataStoreWrapper = require("./Util/DataStoreWrapper")
local Log = require("./Log")
local Types = require("./Types")

type Op = Types.Op
type Reducer<S> = Types.Reducer<S>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper

local RESERVE = "__TransferReserve"
local DELIVER = "__TransferDeliver"
local SETTLE = "__TransferSettle"
local PRUNE = "__TransferPrune"
local EXPIRE = "__TransferExpire"

local RESERVE_ID = "res"
local DELIVER_ID = "del"
local SETTLE_ID = "set"
local PRUNE_ID = "prn"
local EXPIRE_ID = "exp"

local REDRIVE_HORIZON = 7 * 86400
local EXPIRE_MARGIN = 86400
local PRUNE_HORIZON = 30 * 86400

local function Wrap<S>(GameReducer: Reducer<S>, Field: string): Reducer<S>
	local function Combined(State: S, Op: Op): S?
		local Data = State :: { [any]: any }
		local Kind = Op.Kind

		if Kind == RESERVE then
			if Op.Amount > (Data[Field] or 0) then
				return nil
			end
			local Held = table.clone((Data._Held or {}) :: { [any]: any })
			Held[Op.Tid] = { To = Op.To, Amount = Op.Amount, At = Op.At }
			local Next = table.clone(Data)
			Next[Field] = (Data[Field] or 0) - Op.Amount
			Next._Held = if next(Held) == nil then nil else Held
			return Next :: any
		elseif Kind == DELIVER then
			local Received = (Data._Received or {}) :: { [string]: any }
			if Received[Op.Tid] then
				return nil
			end
			local Next = table.clone(Data)
			Next[Field] = (Data[Field] or 0) + Op.Amount
			local NextReceived: { [string]: any } = {}
			local Floor = if type(Op.At) == "number" then Op.At - PRUNE_HORIZON else nil
			for Tid, At in Received do
				if Floor == nil or type(At) ~= "number" or At >= Floor then
					NextReceived[Tid] = At
				end
			end
			NextReceived[Op.Tid] = if type(Op.At) == "number" then Op.At else true
			Next._Received = NextReceived
			return Next :: any
		elseif Kind == EXPIRE then
			local Held = Data._Held :: { [any]: any }?
			local Entry = if Held then Held[Op.Tid] else nil
			if not Entry then
				return nil
			end
			local NextHeld = table.clone(Held :: { [any]: any })
			NextHeld[Op.Tid] = nil
			local Next = table.clone(Data)
			Next[Field] = (Data[Field] or 0) + Entry.Amount
			Next._Held = if next(NextHeld) == nil then nil else NextHeld
			return Next :: any
		elseif Kind == SETTLE then
			if not (Data._Held and Data._Held[Op.Tid]) then
				return nil
			end
			local Held = table.clone(Data._Held :: { [any]: any })
			Held[Op.Tid] = nil
			local Next = table.clone(Data)
			Next._Held = if next(Held) == nil then nil else Held
			return Next :: any
		elseif Kind == PRUNE then
			if Data._Received == nil then
				return nil
			end
			local Next = table.clone(Data)
			Next._Received = nil
			return Next :: any
		end

		local Next = GameReducer(State, Op)
		if type(Next) ~= "table" then
			return Next
		end
		local Merged = table.clone(Next :: { [any]: any })
		Merged._Held = Data._Held
		Merged._Received = Data._Received
		return Merged :: any
	end

	return Combined
end

local WarnedUnwrapped: { [any]: boolean } = {}

local function Reserve(Store: DataStoreWrapper, Reducer: Reducer<any>, Initial: any, From: number | string, To: number | string, Amount: number, Migrations: { Types.Migration }?): string?
	if not (type(Amount) == "number" and Amount > 0 and Amount < math.huge) then
		return nil
	end

	local Tid = HttpService:GenerateGUID(false)
	local ReserveOp: Op = { Id = `{RESERVE_ID}:{Tid}`, Kind = RESERVE, To = To, Amount = Amount, Tid = Tid, At = os.time() }

	local Record = Log.Append(Store, tostring(From), { ReserveOp })
	local State = Log.FoldRecord(Record, Initial, Reducer, Migrations)
	if State._Held and State._Held[Tid] then
		return Tid
	end

	if not WarnedUnwrapped[Reducer] then
		local Probe: any = { Id = "probe", Kind = RESERVE, To = "probe", Amount = 0, Tid = "probe", At = 0 }
		local Ok, Next = pcall(Reducer, State, Probe :: Op)
		if not Ok or type(Next) ~= "table" then
			WarnedUnwrapped[Reducer] = true
			warn("Ledger: a transfer reserve was rejected by a reducer that does not handle transfer ops, every Transfer will fail until the store names a Balance field")
		end
	end
	return nil
end

local function Settle(Store: DataStoreWrapper, From: number | string, Tid: string)
	local SettleOp: Op = { Id = `{SETTLE_ID}:{Tid}`, Kind = SETTLE, Tid = Tid }
	Log.Append(Store, tostring(From), { SettleOp })
end

local function Post(Store: DataStoreWrapper, From: number | string, Tid: string, To: number | string, Amount: number)
	local DeliverOp: Op = { Id = `{DELIVER_ID}:{Tid}`, Kind = DELIVER, From = From, Amount = Amount, Tid = Tid, At = os.time() }
	Log.Append(Store, tostring(To), { DeliverOp })

	Settle(Store, From, Tid)
end

local function Prune(Store: DataStoreWrapper, UserId: number | string)
	local PruneOp: Op = { Id = `{PRUNE_ID}:{HttpService:GenerateGUID(false)}`, Kind = PRUNE }
	Log.Append(Store, tostring(UserId), { PruneOp })
end

local function Drive(Store: DataStoreWrapper, Reducer: Reducer<any>, Initial: any, From: number | string, To: number | string, Amount: number, Migrations: { Types.Migration }?): boolean
	local Tid = Reserve(Store, Reducer, Initial, From, To, Amount, Migrations)
	if not Tid then
		return false
	end
	Post(Store, From, Tid, To, Amount)
	return true
end

local function Expire<S>(Store: DataStoreWrapper, Reducer: Reducer<S>, Initial: S, Migrations: { Types.Migration }?, From: number | string, Tid: string, Entry: any, Age: number?)
	local Record = Log.Read(Store, tostring(Entry.To))
	local State: any = Log.FoldRecord(Record, Initial, Reducer, Migrations)
	local Received = State._Received
	if type(Received) == "table" and Received[Tid] then
		Settle(Store, From, Tid)
		return
	end

	if Age ~= nil and Age <= PRUNE_HORIZON then
		local ExpireOp: Op = { Id = `{EXPIRE_ID}:{Tid}`, Kind = EXPIRE, Tid = Tid }
		Log.Append(Store, tostring(From), { ExpireOp })
		return
	end

	warn(`Ledger: transfer {Tid} from {From} is past the {PRUNE_HORIZON // 86400} day recovery horizon with no delivery on record, settling the hold to avoid a mint. compensate {Entry.Amount} from the audit log if it never delivered`)
	Settle(Store, From, Tid)
end

local function Recover<S>(Store: DataStoreWrapper, Reducer: Reducer<S>, Initial: S, Migrations: { Types.Migration }?, From: number | string, Held: any)
	if type(Held) ~= "table" then
		return
	end
	local Now = os.time()
	for Tid, Entry in Held do
		if type(Entry) ~= "table" then
			continue
		end
		local Age = if type(Entry.At) == "number" then Now - Entry.At else nil
		if Age and Age <= REDRIVE_HORIZON then
			pcall(Post, Store, From, Tid, Entry.To, Entry.Amount)
		elseif Age == nil or Age > REDRIVE_HORIZON + EXPIRE_MARGIN then
			pcall(Expire, Store, Reducer, Initial, Migrations, From, Tid, Entry, Age)
		end
	end
end

return table.freeze({
	Wrap = Wrap,
	Reserve = Reserve,
	Post = Post,
	Prune = Prune,
	Drive = Drive,
	Recover = Recover,
})
