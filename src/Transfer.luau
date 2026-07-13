--!strict
--!optimize 2

--[=[
    Transfer: move a balance across two keys in three legs. reserve the amount into a
    held state on the sender, deliver it to the receiver, then settle the hold.

    each leg is single-key atomic and deduped by transfer id: the receiver keeps a
    durable set of delivered ids so a re-driven deliver can never credit twice, even
    after the log compacts, and the held bookkeeping rides across game ops so an
    unrelated edit cannot drop it. a crash mid-transfer just re-drives from the sender's
    held map, either on their next load or when an operator calls RecoverTransfers.

    there is deliberately no refund or cancel: the sender key cannot see whether the
    deliver leg landed, so refunding a hold could mint. the safe fix for a mistaken
    transfer is to complete it and transfer back. the delivered set grows with received
    transfers; Prune clears it for one account, but only when nothing inbound is still
    in flight, since the set is the double-deliver guard.

    money is never minted, lost, or double-spendable. held money is unspendable.

    Return type: frozen table { Wrap, Reserve, Post, Prune, Drive, Recover }
    Example usage:
        local Transfer = require("./Transfer")
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

local RESERVE_ID = "res"
local DELIVER_ID = "del"
local SETTLE_ID = "set"
local PRUNE_ID = "prn"

local function Wrap<S>(GameReducer: Reducer<S>, Field: string): Reducer<S>
	local function Combined(State: S, Op: Op): S?
		local Data = State :: { [any]: any }
		local Kind = Op.Kind

		if Kind == RESERVE then
			if Op.Amount > (Data[Field] or 0) then
				return nil
			end
			local Held = table.clone((Data._Held or {}) :: { [any]: any })
			Held[Op.Tid] = { To = Op.To, Amount = Op.Amount }
			local Next = table.clone(Data)
			Next[Field] = Data[Field] - Op.Amount
			Next._Held = if next(Held) == nil then nil else Held
			return Next :: any
		elseif Kind == DELIVER then
			local Received = (Data._Received or {}) :: { [string]: boolean }
			if Received[Op.Tid] then
				return nil
			end
			local Next = table.clone(Data)
			Next[Field] = (Data[Field] or 0) + Op.Amount
			local NextReceived = table.clone(Received)
			NextReceived[Op.Tid] = true
			Next._Received = NextReceived
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

local function Reserve(Store: DataStoreWrapper, Reducer: Reducer<any>, Initial: any, From: number, To: number, Amount: number, Migrations: { Types.Migration }?): string?
	if not (type(Amount) == "number" and Amount > 0 and Amount < math.huge) then
		return nil
	end

	local Tid = HttpService:GenerateGUID(false)
	local ReserveOp: Op = { Id = `{RESERVE_ID}:{Tid}`, Kind = RESERVE, To = To, Amount = Amount, Tid = Tid }

	local Record = Log.Append(Store, tostring(From), { ReserveOp })
	local State = Log.FoldRecord(Record, Initial, Reducer, Migrations)
	if State._Held and State._Held[Tid] then
		return Tid
	end
	return nil
end

local function Post(Store: DataStoreWrapper, From: number, Tid: string, To: number, Amount: number)
	local DeliverOp: Op = { Id = `{DELIVER_ID}:{Tid}`, Kind = DELIVER, From = From, Amount = Amount, Tid = Tid }
	Log.Append(Store, tostring(To), { DeliverOp })

	local SettleOp: Op = { Id = `{SETTLE_ID}:{Tid}`, Kind = SETTLE, Tid = Tid }
	Log.Append(Store, tostring(From), { SettleOp })
end

local function Prune(Store: DataStoreWrapper, UserId: number)
	local PruneOp: Op = { Id = `{PRUNE_ID}:{HttpService:GenerateGUID(false)}`, Kind = PRUNE }
	Log.Append(Store, tostring(UserId), { PruneOp })
end

local function Drive(Store: DataStoreWrapper, Reducer: Reducer<any>, Initial: any, From: number, To: number, Amount: number, Migrations: { Types.Migration }?): boolean
	local Tid = Reserve(Store, Reducer, Initial, From, To, Amount, Migrations)
	if not Tid then
		return false
	end
	Post(Store, From, Tid, To, Amount)
	return true
end

local function Recover(Store: DataStoreWrapper, From: number, Held: any)
	if type(Held) ~= "table" then
		return
	end
	for Tid, Entry in Held do
		pcall(Post, Store, From, Tid, Entry.To, Entry.Amount)
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
