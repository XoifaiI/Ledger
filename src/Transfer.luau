--!strict
--!optimize 2

-- moves a balance across two keys in three legs, reserve, deliver, settle. each leg is atomic and deduped by transfer id

local HttpService = game:GetService("HttpService")

local DataStoreWrapper = require("./Util/DataStoreWrapper")
local Dedupe = require("./Dedupe")
local Log = require("./Log")
local Types = require("./Types")

type Op = Types.Op
type Reducer<S> = Types.Reducer<S>
type Reason = Types.Reason
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

local REFUSED: Reason = "Refused"
local BUSY: Reason = "Busy"
local SPENT: Reason = "Spent"
local UNRESOLVED: Reason = "Unresolved"

local function AnyOlderThan(Received: { [string]: any }, Floor: number): boolean
	for _, Stamp in Received do
		if type(Stamp) == "number" and Stamp < Floor then
			return true
		end
	end
	return false
end

local function Remember(Received: any, Id: string, At: any): { [string]: any }
	local Mark = if type(At) == "number" then At else true
	if type(Received) ~= "table" then
		return { [Id] = Mark }
	end

	local Floor = if type(At) == "number" then At - PRUNE_HORIZON else nil

	if Floor == nil or not AnyOlderThan(Received, Floor) then
		local Kept: { [string]: any } = table.clone(Received)
		Kept[Id] = Mark
		return Kept
	end

	local Next: { [string]: any } = {}
	for Tid, Stamp in Received do
		if type(Stamp) ~= "number" or Stamp >= (Floor :: number) then
			Next[Tid] = Stamp
		end
	end
	Next[Id] = Mark
	return Next
end

local function Wrap<S>(GameReducer: Reducer<S>, Field: string): Reducer<S>
	local function Combined(State: S, Op: Op): S?
		local Data = State :: { [any]: any }
		local Kind = Op.Kind

		if Kind == RESERVE then
			if Data._Held and Data._Held[Op.Tid] ~= nil then
				return nil
			end
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
			if Dedupe.Has(Received, Dedupe.TRANSFER, Op.Tid) then
				return nil
			end
			local Next = table.clone(Data)
			Next[Field] = (Data[Field] or 0) + Op.Amount
			Next._Received = Remember(Received, Dedupe.Key(Dedupe.TRANSFER, Op.Tid), Op.At)
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

		local Plain = Next :: { [any]: any }
		if Plain._Held == Data._Held and Plain._Received == Data._Received then
			return Next
		end

		local Merged = table.clone(Plain)
		Merged._Held = Data._Held
		Merged._Received = Data._Received
		return Merged :: any
	end

	return Combined
end

local function Carries(Record: Types.Record<any>, Id: string): boolean
	for _, Op in Record.Ops do
		if Op.Id == Id then
			return true
		end
	end
	for _, Seen in Record.Seen do
		if Seen == Id then
			return true
		end
	end
	return false
end

local function LandedOn(Format: Log.Shape<any>, Record: Types.Record<any>, Tid: string): boolean
	if Carries(Record, `{DELIVER_ID}:{Tid}`) then
		return true
	end

	local State: any = Format:Fold(Record)
	return Dedupe.Has(State._Received, Dedupe.TRANSFER, Tid)
end

local function Delivered(Records: Log.Log, Format: Log.Shape<any>, To: number | string, Tid: string): boolean
	return LandedOn(Format, Records:Read(tostring(To)), Tid)
end

local function Reserve(Records: Log.Log, Format: Log.Shape<any>, From: number | string, To: number | string, Amount: number, Id: string?): (string?, Reason?)
	if not (type(Amount) == "number" and Amount > 0 and Amount < math.huge) then
		return nil, REFUSED
	end

	local Tid = Id or HttpService:GenerateGUID(false)

	if Id ~= nil and Delivered(Records, Format, To, Tid) then
		return nil, nil
	end

	local ReserveOp: Op = { Id = `{RESERVE_ID}:{Tid}`, Kind = RESERVE, To = To, Amount = Amount, Tid = Tid, At = os.time() }

	local Record = Records:AppendUnlessPending(tostring(From), { ReserveOp })
	local State = Format:Fold(Record)

	if State._Held and State._Held[Tid] then
		return Tid, nil
	end

	if Carries(Record, `{SETTLE_ID}:{Tid}`) then
		return nil, nil
	end
	if Carries(Record, `{EXPIRE_ID}:{Tid}`) then
		return nil, SPENT
	end

	if Log.HasPending(Record) then
		return nil, BUSY
	end

	local Probe: any = { Id = "probe", Kind = RESERVE, To = "probe", Amount = 0, Tid = "probe", At = 0 }
	local Handles, Next = pcall(Format.Reducer, State, Probe :: Op)
	if not Handles or type(Next) ~= "table" then
		warn("Ledger: a transfer reserve was rejected by a reducer that does not handle transfer ops, every Transfer will fail until the store names a Balance field")
	end
	return nil, REFUSED
end

local function Settle(Records: Log.Log, From: number | string, Tid: string)
	local SettleOp: Op = { Id = `{SETTLE_ID}:{Tid}`, Kind = SETTLE, Tid = Tid }
	Records:Append(tostring(From), { SettleOp })
end

local function Post(Records: Log.Log, From: number | string, Tid: string, To: number | string, Amount: number)
	local DeliverOp: Op = { Id = `{DELIVER_ID}:{Tid}`, Kind = DELIVER, From = From, Amount = Amount, Tid = Tid, At = os.time() }
	Records:Append(tostring(To), { DeliverOp })

	Settle(Records, From, Tid)
end

local function Prune(Records: Log.Log, UserId: number | string)
	local PruneOp: Op = { Id = `{PRUNE_ID}:{HttpService:GenerateGUID(false)}`, Kind = PRUNE }
	Records:Append(tostring(UserId), { PruneOp })
end

local function Drive(Records: Log.Log, Format: Log.Shape<any>, From: number | string, To: number | string, Amount: number, Id: string?): (boolean, Reason?, boolean?)
	local Fine, Tid, Why = pcall(Reserve, Records, Format, From, To, Amount, Id)
	if not Fine then
		return false, UNRESOLVED, nil
	end

	if Tid == nil then
		if Why == nil then
			return true, nil, nil
		end
		return false, Why :: Reason, nil
	end
	if (pcall(Post, Records, From, Tid :: string, To, Amount)) then
		return true, nil, nil
	end

	warn(
		`Ledger: transfer {Tid} from {From} took the money but could not hand it over. it is set aside, and Ledger will either finish the transfer or give it back on its own`
	)
	return false, UNRESOLVED, true
end

local function Expire(Records: Log.Log, Format: Log.Shape<any>, From: number | string, Tid: string, Entry: any, Age: number?)
	if LandedOn(Format, Records:Read(tostring(Entry.To)), Tid) then
		Settle(Records, From, Tid)
		return
	end

	if Age ~= nil and Age <= PRUNE_HORIZON then
		local ExpireOp: Op = { Id = `{EXPIRE_ID}:{Tid}`, Kind = EXPIRE, Tid = Tid }
		Records:Append(tostring(From), { ExpireOp })
		return
	end

	warn(`Ledger: transfer {Tid} from {From} has been stuck for over {PRUNE_HORIZON // 86400} days and the receiver has no record of it. giving the money back could pay them twice, so it is being written off instead. check the audit log and pay {Entry.Amount} back by hand if it never arrived`)
	Settle(Records, From, Tid)
end

local function Recover(Records: Log.Log, Format: Log.Shape<any>, From: number | string, Held: any)
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
			local Ok, Reason = pcall(function(): any
				Post(Records, From, Tid, Entry.To, Entry.Amount)
				return nil
			end)
			if not Ok then
				warn(`Ledger: could not send transfer {Tid} from {From} again, the money stays set aside and the next recovery will try once more: {Reason}`)
			end
		elseif Age == nil or Age > REDRIVE_HORIZON + EXPIRE_MARGIN then
			local Ok, Reason = pcall(function(): any
				Expire(Records, Format, From, Tid, Entry, Age)
				return nil
			end)
			if not Ok then
				warn(`Ledger: could not give back transfer {Tid} from {From}, the money stays set aside and the next recovery will try once more: {Reason}`)
			end
		end
	end
end

return table.freeze({
	Wrap = Wrap,
	Remember = Remember,
	Reserve = Reserve,
	Post = Post,
	Prune = Prune,
	Drive = Drive,
	Recover = Recover
})
