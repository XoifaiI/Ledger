--!strict
--!optimize 2

-- moves a balance across two keys in three legs, reserve, deliver, settle. each leg is atomic and deduped by transfer id

local DataStoreWrapper = require("./Util/DataStoreWrapper")
local Clock = require("./Clock")
local Fault = require("./Fault")
local Dedupe = require("./Record/Dedupe")
local Fingerprint = require("./Record/Fingerprint")
local Ident = require("./Record/Ident")
local Log = require("./Record/Log")
local Reasons = require("./Reason")
local Step = require("./Record/Step")
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
local TOMB_HORIZON = Log.TOMB_HORIZON

assert(
	REDRIVE_HORIZON + EXPIRE_MARGIN == TOMB_HORIZON,
	"a tomb has to outlast the last redelivery of a transfer, or money could be sent to a key that has already stopped turning it away"
)

local REFUSED = Reasons.Refused
local BUSY = Reasons.Busy
local SPENT = Reasons.Spent
local HELD = Reasons.Held

local function AnyOlderThan(Received: { [string]: any }, Floor: number): boolean
	for _, Stamp in Received do
		local When = Dedupe.At(Stamp)
		if When ~= nil and When < Floor then
			return true
		end
	end
	return false
end

local function Remember(Received: any, Id: string, At: any, Print: string?): { [string]: any }
	local Mark = Dedupe.Entry(At, Print)
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
		local When = Dedupe.At(Stamp)
		if When == nil or When >= (Floor :: number) then
			Next[Tid] = Stamp
		end
	end
	Next[Id] = Mark
	return Next
end

local function Some(Entries: { [any]: any }): { [any]: any }?
	return if next(Entries) == nil then nil else Entries
end

local function Holding(Data: { [any]: any }): number
	local Held = Data._Held
	if type(Held) ~= "table" then
		return 0
	end

	local Count = 0
	for _ in Held do
		Count += 1
	end
	return Count
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

	if Next[Field] < 0 then
		Fault.Broke(`setting {Op.Amount} aside for transfer {Op.Tid} took '{Field}' below zero`)
		return nil
	end
	if Holding(Next) ~= Holding(Data) + 1 then
		Fault.Broke(`setting aside for transfer {Op.Tid} did not leave exactly one more hold on the key`)
		return nil
	end
	return Next
end

local function Delivering(Data: { [any]: any }, Op: Op, Field: string): { [any]: any }?
	local Received = (Data._Received or {}) :: { [string]: any }
	if Dedupe.Has(Received, Dedupe.TRANSFER, Op.Tid) then
		return nil
	end

	local Next = table.clone(Data)
	Next[Field] = (Data[Field] or 0) + Op.Amount
	Next._Received = Remember(Received, Dedupe.Key(Dedupe.TRANSFER, Op.Tid), Op.At, Op.Print)

	if not Dedupe.Has(Next._Received, Dedupe.TRANSFER, Op.Tid) then
		Fault.Broke(`transfer {Op.Tid} was paid in without being remembered, so the same delivery could pay again`)
		return nil
	end
	if Holding(Next) ~= Holding(Data) then
		Fault.Broke(`paying in transfer {Op.Tid} changed what the receiver has set aside`)
		return nil
	end
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

	if Holding(Next) ~= Holding(Data) - 1 then
		Fault.Broke(`giving transfer {Op.Tid} back did not clear exactly the one hold it was held under`)
		return nil
	end
	if Next[Field] < (Data[Field] or 0) then
		Fault.Broke(`giving transfer {Op.Tid} back left the sender with less than they started with`)
		return nil
	end
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
	Next._Received = Remember(Data._Received, Dedupe.Key(Dedupe.SENT, Op.Tid), Op.At, Op.Print)

	if Holding(Next) ~= Holding(Data) - 1 then
		Fault.Broke(`finishing transfer {Op.Tid} did not clear exactly the one hold it was held under`)
		return nil
	end
	return Next
end

local function Pruning(Data: { [any]: any }, Op: Op): { [any]: any }?
	local Received = Data._Received
	if type(Received) ~= "table" or type(Op.At) ~= "number" then
		return nil
	end

	local Floor = Op.At - PRUNE_HORIZON
	local Kept: { [string]: any } = {}
	local Dropped = false
	for Id, Stamp in Received do
		local When = Dedupe.At(Stamp)
		if When == nil or When >= Floor then
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

	if Plain._Held ~= nil and Plain._Held ~= Data._Held then
		Fault.Broke("your reducer wrote its own _Held, so Ledger put the money set aside back")
	end
	if Plain._Received ~= nil and Plain._Received ~= Data._Received then
		Fault.Broke("your reducer wrote its own _Received, so Ledger put the applied names back")
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
			return Pruning(Data, Op) :: any
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

local function Terms(To: number | string, Amount: number): string
	return Fingerprint.Of(Fingerprint.Canon({ To = tostring(To), Amount = Amount }))
end

local function Written(Record: Types.Record<any>, Id: string): (boolean, string?)
	for _, Op in Record.Ops do
		if Op.Id == Id then
			return true, Op.Print
		end
	end
	for _, Seen in Record.Seen do
		if Seen == Id then
			return true, nil
		end
	end
	return false, nil
end

local function LandedOn(Format: Log.Shape<any>, Record: Types.Record<any>, Tid: string, Print: string?): Dedupe.Recalled
	local Held, Meant = Written(Record, `{DELIVER_ID}:{Tid}`)
	if Held then
		if Meant == nil or Print == nil then
			return Dedupe.SAME
		end
		return if Meant == Print then Dedupe.SAME else Dedupe.OTHER
	end

	local State: any = Format:Fold(Record)
	return Dedupe.Recall(State._Received, Dedupe.TRANSFER, Tid, Print)
end

local function Delivered(Records: Log.Log, Format: Log.Shape<any>, To: number | string, Tid: string, Print: string?): Dedupe.Recalled
	return LandedOn(Format, Records:Read(tostring(To)), Tid, Print)
end

local function Reserve(Records: Log.Log, Format: Log.Shape<any>, From: number | string, To: number | string, Amount: number, Id: string?): Reserved
	if not (type(Amount) == "number" and Amount > 0 and Amount < math.huge) then
		return { Outcome = "Stopped", Why = REFUSED }
	end

	local Tid = Id or Ident.Fresh()
	local Print = Terms(To, Amount)

	if Id ~= nil then
		local Already = Delivered(Records, Format, To, Tid, Print)
		if Already == Dedupe.SAME then
			return { Outcome = "Finished" }
		end
		if Already == Dedupe.OTHER then
			warn(
				`Ledger: transfer {Tid} already went through for a different amount or a different key, and a name has to mean the same thing every time. nothing was sent, so pick a new name`
			)
			return { Outcome = "Stopped", Why = SPENT }
		end
	end

	local ReserveOp: Op = { Id = `{RESERVE_ID}:{Tid}`, Kind = RESERVE, To = To, Amount = Amount, Tid = Tid, At = Clock.Now() }

	local Record = Records:Append(tostring(From), { ReserveOp }, function(Stored: Types.Record<any>): boolean
		if Log.HasPending(Stored) then
			return false
		end
		return Step(Format.Reducer, Format:Fold(Log.Detached(Stored)), ReserveOp) ~= nil
	end)
	local State = Format:Fold(Record)

	local Holds: any = State._Held
	local Escrowed: Hold? = if type(Holds) == "table" then Holds[Tid] else nil
	if Escrowed ~= nil then
		if Escrowed.To ~= To or Escrowed.Amount ~= Amount then
			warn(`Ledger: transfer {Tid} already has {Escrowed.Amount} set aside for {Escrowed.To}, so that is what it pays out, not the {Amount} to {To} you just asked for`)
		end
		return { Outcome = "Escrowed", Tid = Tid, Hold = Escrowed }
	end

	local Spend = Dedupe.Recall((State :: any)._Received, Dedupe.SENT, Tid, Print)
	if Spend == Dedupe.OTHER then
		warn(
			`Ledger: transfer {Tid} already went through for a different amount or a different key, and a name has to mean the same thing every time. nothing was sent, so pick a new name`
		)
		return { Outcome = "Stopped", Why = SPENT }
	end
	if Spend == Dedupe.SAME or Carries(Record, `{SETTLE_ID}:{Tid}`) then
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

local function Settle(Records: Log.Log, From: number | string, Tid: string, Print: string?): Types.Record<any>
	local SettleOp: Op = { Id = `{SETTLE_ID}:{Tid}`, Kind = SETTLE, Tid = Tid, At = Clock.Now(), Print = Print }
	return Records:Append(tostring(From), { SettleOp })
end

local function NotEntombed(Record: Types.Record<any>): boolean
	return not Log.Entombed(Record)
end

local function Post(Records: Log.Log, Format: Log.Shape<any>, From: number | string, Tid: string, To: number | string, Amount: number)
	Fault.Holds(tostring(From) ~= tostring(To), `transfer {Tid} is being delivered to the key it came from, so the money would be counted twice`)
	Fault.Holds(Amount > 0, `transfer {Tid} is being delivered with nothing in it`)

	local DeliverOp: Op = { Id = `{DELIVER_ID}:{Tid}`, Kind = DELIVER, From = From, Amount = Amount, Tid = Tid, At = Clock.Now(), Print = Terms(To, Amount) }
	local Landed = Records:Append(tostring(To), { DeliverOp }, NotEntombed)
	if not Carries(Landed, DeliverOp.Id) then
		error(Fault.New(HELD, `'{To}' was erased, so transfer {Tid} cannot be delivered. the {Amount} has already left '{From}' and stays set aside until it is given back`))
	end

	local Cleared = Settle(Records, From, Tid, Terms(To, Amount))
	Fault.Holds(
		Carries(Cleared, `{SETTLE_ID}:{Tid}`),
		`transfer {Tid} was delivered to '{To}' but the hold on '{From}' was not settled, so the money is on both keys`
	)

	Records:Trim(tostring(To), Format, Landed)
	Records:Trim(tostring(From), Format, Cleared)
end

local function Prune(Records: Log.Log, UserId: number | string)
	local PruneOp: Op = { Id = `{PRUNE_ID}:{Ident.Fresh()}`, Kind = PRUNE, At = Clock.Now() }
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
	return false, Fault.Named(Why), true
end

local function Expire(Records: Log.Log, Format: Log.Shape<any>, From: number | string, Tid: string, Entry: any, Age: number?)
	if LandedOn(Format, Records:Read(tostring(Entry.To)), Tid, nil) ~= Dedupe.UNSEEN then
		Settle(Records, From, Tid, Terms(Entry.To, Entry.Amount))
		return
	end

	if Age == nil or Age <= PRUNE_HORIZON then
		local ExpireOp: Op = { Id = `{EXPIRE_ID}:{Tid}`, Kind = EXPIRE, Tid = Tid }
		Records:Append(tostring(From), { ExpireOp })
		return
	end

	assert(Age > PRUNE_HORIZON, "a transfer is being written off before it is old enough, so money would be destroyed early")

	warn(`Ledger: transfer {Tid} from {From} has been stuck over {PRUNE_HORIZON // 86400} days and the receiver has no record of it. a refund could pay them twice, so it is written off. check the audit log and pay {Entry.Amount} back by hand if it never arrived`)
	Settle(Records, From, Tid, Terms(Entry.To, Entry.Amount))
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

local function Recover(Records: Log.Log, Format: Log.Shape<any>, From: number | string, Held: any): (boolean, boolean)
	if type(Held) ~= "table" then
		return true, false
	end

	local Now = Clock.Now()
	local Failures, Handled, Waiting, Moved = 0, 0, 0, 0

	for Tid, Entry in Held do
		if type(Entry) ~= "table" then
			continue
		end

		local Age = if type(Entry.At) == "number" then Now - Entry.At else nil
		local Fresh = Age ~= nil and Age <= REDRIVE_HORIZON
		local Overdue = Age == nil or Age > REDRIVE_HORIZON + EXPIRE_MARGIN
		assert(not (Fresh and Overdue), `transfer {Tid} counts as both still worth sending and long overdue, so recovery cannot tell whether to deliver it or give it back`)

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
		if Ok then
			Moved += 1
		else
			Failures += 1
		end
	end

	if Waiting > 0 then
		warn(`Ledger: {From} has more than {RECOVER_LIMIT} unfinished transfers, so {Waiting} of them wait for the next recovery`)
	end

	assert(Handled <= RECOVER_LIMIT, "one recovery pass took on more holds than its own limit allows")
	assert(Moved + Failures == Handled, "a recovery pass neither finished nor failed one of the holds it took on")
	return Failures == 0 and Waiting == 0, Moved > 0
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
