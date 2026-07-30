--!strict
--!optimize 2

-- moves a balance across two keys in three legs, reserve, deliver, settle. each leg is atomic and deduped by transfer id

local HttpService = game:GetService("HttpService")

local DataStoreWrapper = require("./Util/DataStoreWrapper")
local Clock = require("./Clock")
local Fault = require("./Fault")
local Dedupe = require("./Record/Dedupe")
local Log = require("./Record/Log")
local Reasons = require("./Reason")
local Types = require("./Types")

type Op = Types.Op
type Reducer<S> = Types.Reducer<S>
type Reason = Types.Reason
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper

type Hold = { To: number | string, Amount: number, At: number }

type Reserved =
	{ read Outcome: "Finished" }
	| { read Outcome: "Escrowed", read Tid: string, read Hold: Hold }
	| { read Outcome: "Stopped", read Why: Reason }

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
local RECOVER_LIMIT = 32

local REFUSED = Reasons.Refused
local BUSY = Reasons.Busy
local SPENT = Reasons.Spent
local UNRESOLVED = Reasons.Unresolved

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

local function Some(Entries: { [any]: any }): { [any]: any }?
	return if next(Entries) == nil then nil else Entries
end

local function Reserving(Data: { [any]: any }, Op: Op, Field: string): { [any]: any }?
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
	Next._Held = Some(Held)
	return Next
end

local function Delivering(Data: { [any]: any }, Op: Op, Field: string): { [any]: any }?
	local Received = (Data._Received or {}) :: { [string]: any }
	if Dedupe.Has(Received, Dedupe.TRANSFER, Op.Tid) then
		return nil
	end

	local Next = table.clone(Data)
	Next[Field] = (Data[Field] or 0) + Op.Amount
	Next._Received = Remember(Received, Dedupe.Key(Dedupe.TRANSFER, Op.Tid), Op.At)
	return Next
end

local function Expiring(Data: { [any]: any }, Op: Op, Field: string): { [any]: any }?
	local Held = Data._Held :: { [any]: any }?
	local Entry = if Held then Held[Op.Tid] else nil
	if not Entry then
		return nil
	end

	local Rest = table.clone(Held :: { [any]: any })
	Rest[Op.Tid] = nil

	local Next = table.clone(Data)
	Next[Field] = (Data[Field] or 0) + Entry.Amount
	Next._Held = Some(Rest)
	return Next
end

local function Settling(Data: { [any]: any }, Op: Op): { [any]: any }?
	if not (Data._Held and Data._Held[Op.Tid]) then
		return nil
	end

	local Held = table.clone(Data._Held :: { [any]: any })
	Held[Op.Tid] = nil

	local Next = table.clone(Data)
	Next._Held = Some(Held)
	return Next
end

local function Pruning(Data: { [any]: any }): { [any]: any }?
	local Received = Data._Received
	if type(Received) ~= "table" then
		return nil
	end

	local Kept: { [string]: any } = {}
	local Dropped = false
	for Id, Stamp in Received do
		if Dedupe.Tagged(Id, Dedupe.ONCE) or Dedupe.Tagged(Id, Dedupe.TX) then
			Kept[Id] = Stamp
		else
			Dropped = true
		end
	end
	if not Dropped then
		return nil
	end

	local Next = table.clone(Data)
	Next._Received = Some(Kept)
	return Next
end

local function Carried(Next: any, Data: { [any]: any }): any
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
	return Merged
end

local function Wrap<S>(GameReducer: Reducer<S>, Field: string): Reducer<S>
	local function Combined(State: S, Op: Op): S?
		local Data = State :: { [any]: any }
		local Kind = Op.Kind

		if Kind == RESERVE then
			return Reserving(Data, Op, Field) :: any
		elseif Kind == DELIVER then
			return Delivering(Data, Op, Field) :: any
		elseif Kind == EXPIRE then
			return Expiring(Data, Op, Field) :: any
		elseif Kind == SETTLE then
			return Settling(Data, Op) :: any
		elseif Kind == PRUNE then
			return Pruning(Data) :: any
		end

		return Carried(GameReducer(State, Op), Data) :: any
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

local function Reserve(Records: Log.Log, Format: Log.Shape<any>, From: number | string, To: number | string, Amount: number, Id: string?): Reserved
	if not (type(Amount) == "number" and Amount > 0 and Amount < math.huge) then
		return { Outcome = "Stopped", Why = REFUSED }
	end

	local Tid = Id or HttpService:GenerateGUID(false)

	if Id ~= nil and Delivered(Records, Format, To, Tid) then
		return { Outcome = "Finished" }
	end

	local ReserveOp: Op = { Id = `{RESERVE_ID}:{Tid}`, Kind = RESERVE, To = To, Amount = Amount, Tid = Tid, At = Clock.Now() }

	local Record = Records:AppendUnlessPending(tostring(From), { ReserveOp })
	local State = Format:Fold(Record)

	local Holds: any = State._Held
	local Escrowed: Hold? = if type(Holds) == "table" then Holds[Tid] else nil
	if Escrowed ~= nil then
		if Escrowed.To ~= To or Escrowed.Amount ~= Amount then
			warn(`Ledger: transfer {Tid} already has {Escrowed.Amount} set aside for {Escrowed.To}, so that is what it pays out, not the {Amount} to {To} you just asked for`)
		end
		return { Outcome = "Escrowed", Tid = Tid, Hold = Escrowed }
	end

	if Carries(Record, `{SETTLE_ID}:{Tid}`) then
		return { Outcome = "Finished" }
	end
	if Carries(Record, `{EXPIRE_ID}:{Tid}`) then
		return { Outcome = "Stopped", Why = SPENT }
	end
	if Log.HasPending(Record) then
		return { Outcome = "Stopped", Why = BUSY }
	end

	return { Outcome = "Stopped", Why = REFUSED }
end

local function Settle(Records: Log.Log, From: number | string, Tid: string): Types.Record<any>
	local SettleOp: Op = { Id = `{SETTLE_ID}:{Tid}`, Kind = SETTLE, Tid = Tid }
	return Records:Append(tostring(From), { SettleOp })
end

local function Post(Records: Log.Log, Format: Log.Shape<any>, From: number | string, Tid: string, To: number | string, Amount: number)
	local DeliverOp: Op = { Id = `{DELIVER_ID}:{Tid}`, Kind = DELIVER, From = From, Amount = Amount, Tid = Tid, At = Clock.Now() }
	local Landed = Records:Append(tostring(To), { DeliverOp })
	local Cleared = Settle(Records, From, Tid)

	Records:Trim(tostring(To), Format, Landed)
	Records:Trim(tostring(From), Format, Cleared)
end

local function Prune(Records: Log.Log, UserId: number | string)
	local PruneOp: Op = { Id = `{PRUNE_ID}:{HttpService:GenerateGUID(false)}`, Kind = PRUNE }
	Records:Append(tostring(UserId), { PruneOp })
end

local function Drive(Records: Log.Log, Format: Log.Shape<any>, From: number | string, To: number | string, Amount: number, Id: string?): (boolean, Reason?, boolean?)
	local Fine, Ruling = pcall(Reserve, Records, Format, From, To, Amount, Id)
	if not Fine then
		return false, Fault.Named(Ruling), nil
	end

	if Ruling.Outcome == "Finished" then
		return true, nil, nil
	end
	if Ruling.Outcome == "Stopped" then
		return false, Ruling.Why, nil
	end

	local Tid, Hold = Ruling.Tid, Ruling.Hold
	local Handed, Why = pcall(function()
		Post(Records, Format, From, Tid, Hold.To, Hold.Amount)
	end)
	if Handed then
		return true, nil, nil
	end

	warn(
		`Ledger: transfer {Tid} from {From} took the money but could not hand it over. it is set aside, and Ledger finishes or refunds it on its own: {Why}`
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

	warn(`Ledger: transfer {Tid} from {From} has been stuck over {PRUNE_HORIZON // 86400} days and the receiver has no record of it. a refund could pay them twice, so it is written off. check the audit log and pay {Entry.Amount} back by hand if it never arrived`)
	Settle(Records, From, Tid)
end

local function Redeliver(Records: Log.Log, Format: Log.Shape<any>, From: number | string, Tid: string, Entry: any): boolean
	local Ok, Reason = pcall(function()
		Post(Records, Format, From, Tid, Entry.To, Entry.Amount)
	end)
	if not Ok then
		warn(`Ledger: could not send transfer {Tid} from {From} again. the money stays set aside and the next recovery has another go: {Reason}`)
	end
	return Ok
end

local function GiveBack(Records: Log.Log, Format: Log.Shape<any>, From: number | string, Tid: string, Entry: any, Age: number?): boolean
	local Ok, Reason = pcall(function()
		Expire(Records, Format, From, Tid, Entry, Age)
	end)
	if not Ok then
		warn(`Ledger: could not give back transfer {Tid} from {From}. the money stays set aside and the next recovery has another go: {Reason}`)
	end
	return Ok
end

local function Recover(Records: Log.Log, Format: Log.Shape<any>, From: number | string, Held: any): boolean
	if type(Held) ~= "table" then
		return true
	end

	local Now = Clock.Now()
	local Failures, Handled, Waiting = 0, 0, 0

	for Tid, Entry in Held do
		if type(Entry) ~= "table" then
			continue
		end

		local Age = if type(Entry.At) == "number" then Now - Entry.At else nil
		local Fresh = Age ~= nil and Age <= REDRIVE_HORIZON
		local Overdue = Age == nil or Age > REDRIVE_HORIZON + EXPIRE_MARGIN
		if not Fresh and not Overdue then
			continue
		end

		if Handled >= RECOVER_LIMIT then
			Waiting += 1
			continue
		end
		Handled += 1

		local Ok = if Fresh
			then Redeliver(Records, Format, From, Tid, Entry)
			else GiveBack(Records, Format, From, Tid, Entry, Age)
		if not Ok then
			Failures += 1
		end
	end

	if Waiting > 0 then
		warn(`Ledger: {From} has more than {RECOVER_LIMIT} unfinished transfers, so {Waiting} of them wait for the next recovery`)
	end

	return Failures == 0 and Waiting == 0
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
