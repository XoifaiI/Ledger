--!strict
--!optimize 2

--[=[

	Transfer: Moves a balance across two keys in three legs.

	Reserve sets the money aside on the sender, Post delivers it to the receiver, and Settle clears
	the hold. Each leg is one op, atomic on its own key, and the transfer id makes each apply once.
	The money arrives before the hold clears, so a server that stops leaves it set aside for recovery.

	Return type: A table with Reserve, Post, Settle, Prune, Drive, Terms and LandedOn.
	Example usage:
		local Transfer = require("./Transfer")
		local Ok, Why = Transfer.Drive(Books, Format, "a", "b", 30, "tip1")
--]=]

local Clock = require("../Util/Clock")
local Windows = require("../Core/Constants/Windows")
local Errors = require("../Core/Errors")
local Reasons = require("../Core/Constants/Reasons")
local Shapes = require("../Core/Shapes")
local Validate = require("../Core/Validate")
local Tags = require("../Core/Constants/Tags")
local Applied = require("../Core/Applied")
local Digest = require("../Encode/Digest")
local Ids = require("../Encode/Ids")
local Log = require("../Record/Log")
local LogTypes = require("../Record/Types")
local TxStamp = require("../Record/TxStamp")
local Apply = require("../Record/Apply")
local Schema = require("../Record/Schema")
local Kinds = require("../Core/Constants/Kinds")
local Escrow = require("../Layers/Escrow")

type Op = Shapes.Op
type Record = Shapes.Record<any>
type Reason = Reasons.Reason
type Log = LogTypes.Log
type Format = LogTypes.Shape<any>

export type Hold = Shapes.Held

export type Reserved = { read Outcome: "Finished" } | { read Outcome: "Escrowed", read Tid: string, read Hold: Hold } | { read Outcome: "Stopped", read Why: Reason }

local REFUSED = Reasons.Refused
local BUSY = Reasons.Busy
local SPENT = Reasons.Spent
local HELD = Reasons.Held

local function Stopped(Why: Reason): Reserved
	return { Outcome = "Stopped", Why = Why }
end

local function Spent(Tid: string): Reserved
	warn(`Ledger: transfer {Tid} already went through for a different amount or a different key, and a name has to mean the same thing every time. nothing was sent, so pick a new name`)
	return Stopped(SPENT)
end

local function Terms(From: number | string, To: number | string, Amount: number): string
	return Digest.Of(Digest.Canon({ From = tostring(From), To = tostring(To), Amount = Amount }))
end

local function LandedOn(Format: Format, Record: Record, Tid: string, Print: string?, From: (number | string)?): Applied.Recalled
	local Held, Meant, Sender = TxStamp.Written(Record, `{Kinds.DELIVER_ID}:{Tid}`)
	if Held and Print ~= nil and Sender ~= nil and From ~= nil and tostring(Sender) ~= tostring(From) then
		return Tags.OTHER
	end

	if Held and Meant ~= nil and Print ~= nil then
		return if Meant == Print then Tags.SAME else Tags.OTHER
	end

	if Held and Print == nil then
		return Tags.SAME
	end

	local State: any = Format:Fold(Record)
	return Applied.Recall(State._Received, Tags.TRANSFER, Tid, Print)
end

local function Delivered(Records: Log, Format: Format, To: number | string, Tid: string, Print: string?, From: (number | string)?): Applied.Recalled
	return LandedOn(Format, Records:Read(tostring(To)), Tid, Print, From)
end

local function Reserve(Records: Log, Format: Format, From: number | string, To: number | string, Amount: number, Id: string?): Reserved
	if not Validate.Positive(Amount) then
		return Stopped(REFUSED)
	end

	local Tid = Id or Ids.Fresh()
	local Print = Terms(From, To, Amount)

	if Id ~= nil then
		local Already = Delivered(Records, Format, To, Tid, Print, From)
		if Already == Tags.SAME then
			return { Outcome = "Finished" }
		end
		if Already == Tags.OTHER then
			return Spent(Tid)
		end
	end

	local ReserveOp: Op = { Id = `{Kinds.RESERVE_ID}:{Tid}`, Kind = Kinds.RESERVE, To = To, Amount = Amount, Tid = Tid, At = Clock.Now() }

	local Record = Records:Append(tostring(From), { ReserveOp }, function(Stored: Record): boolean
		if TxStamp.HasPending(Stored) then
			return false
		end
		return Apply(Format.Reducer, Format:Fold(Schema.Detached(Stored)), ReserveOp) ~= nil
	end)
	local State = Format:Fold(Record)

	local Escrowed = Escrow.Entry(State._Held, Tid)
	if Escrowed ~= nil then
		if Escrowed.To ~= To or Escrowed.Amount ~= Amount then
			warn(`Ledger: transfer {Tid} already has {Escrowed.Amount} set aside for {Escrowed.To}, so that is what it pays out, not the {Amount} to {To} you just asked for`)
		end

		local At = Escrowed.At
		if At ~= nil and Clock.Now() - At > Windows.REDRIVE then
			warn(
				`Ledger: transfer {Tid} from {From} has been set aside longer than Ledger sends one again, so recovery owns it now and this call left it alone. it is finished or given back on its own`
			)
			return Stopped(HELD)
		end

		return { Outcome = "Escrowed", Tid = Tid, Hold = Escrowed }
	end

	local Spend = Applied.Recall(State._Received, Tags.SENT, Tid, Print)
	if Spend == Tags.OTHER then
		return Spent(Tid)
	end
	if Spend == Tags.SAME or TxStamp.Carries(Record, `{Kinds.SETTLE_ID}:{Tid}`) then
		return { Outcome = "Finished" }
	end
	if TxStamp.Carries(Record, `{Kinds.EXPIRE_ID}:{Tid}`) then
		return Stopped(SPENT)
	end
	if TxStamp.HasPending(Record) then
		return Stopped(BUSY)
	end

	return Stopped(REFUSED)
end

local function Settle(Records: Log, From: number | string, Tid: string, Print: string?): Record
	local SettleOp: Op = { Id = `{Kinds.SETTLE_ID}:{Tid}`, Kind = Kinds.SETTLE, Tid = Tid, At = Clock.Now(), Print = Print }
	return (Records:Append(tostring(From), { SettleOp }))
end

local function Sound(At: number?): boolean
	return type(At) ~= "number" or Clock.Now() - At <= Windows.REDRIVE + Windows.EXPIRE_MARGIN
end

local function Post(Records: Log, Format: Format, From: number | string, Tid: string, To: number | string, Amount: number, At: number?)
	assert(tostring(From) ~= tostring(To), `transfer {Tid} is being delivered to the key it came from, so the money would be counted twice`)
	assert(Amount > 0, `transfer {Tid} is being delivered with nothing in it`)

	local Print = Terms(From, To, Amount)
	local DeliverOp: Op = { Id = `{Kinds.DELIVER_ID}:{Tid}`, Kind = Kinds.DELIVER, From = From, Amount = Amount, Tid = Tid, At = Clock.Now(), Print = Print }
	local Landed = Records:Append(tostring(To), { DeliverOp }, function(Record: Record): boolean
		return Sound(At) and Log.NotEntombed(Record)
	end)
	if not TxStamp.Carries(Landed, DeliverOp.Id) then
		if not Sound(At) then
			Errors.Raise(
				HELD,
				`transfer {Tid} reached '{To}' later than the window it is given back in, so it was not delivered. the {Amount} stays set aside on '{From}' until recovery gives it back`
			)
		end
		Errors.Raise(HELD, `'{To}' was erased, so transfer {Tid} cannot be delivered. the {Amount} has already left '{From}' and stays set aside until it is given back`)
	end

	local Landing = LandedOn(Format, Landed, Tid, DeliverOp.Print, From)
	if Landing == Tags.OTHER then
		Errors.Raise(
			SPENT,
			`transfer {Tid} cannot be delivered to '{To}', a different transfer already went through under that name. the {Amount} stays set aside on '{From}' until it is given back, and a transfer name belongs to one sender`
		)
	end
	if Landing == Tags.UNSEEN then
		Errors.Raise(
			HELD,
			`transfer {Tid} cannot be shown to have reached '{To}'. its delivery was folded into the snapshot and the name has aged out, so the {Amount} stays set aside on '{From}' rather than settle against a delivery that may belong to someone else`
		)
	end

	local Cleared = Settle(Records, From, Tid, Print)
	assert(Applied.Has(Format:Fold(Cleared)._Received, Tags.SENT, Tid), `transfer {Tid} was delivered to '{To}' but the hold on '{From}' was not settled, so the money is on both keys`)

	Records:Trim(tostring(To), Format, Landed)
	Records:Trim(tostring(From), Format, Cleared)
end

local function Prune(Records: Log, UserId: number | string)
	local PruneOp: Op = { Id = `{Kinds.PRUNE_ID}:{Ids.Fresh()}`, Kind = Kinds.PRUNE, At = Clock.Now() }
	Records:Append(tostring(UserId), { PruneOp })
end

local function Drive(Records: Log, Format: Format, From: number | string, To: number | string, Amount: number, Id: string?): (boolean, Reason?, boolean?)
	local Fine, Ruling = pcall(Reserve, Records, Format, From, To, Amount, Id)
	if not Fine then
		return false, Errors.Reason(Ruling), nil
	end

	if Ruling.Outcome == "Finished" then
		return true, nil, nil
	end
	if Ruling.Outcome == "Stopped" then
		return false, Ruling.Why, nil
	end
	if Ruling.Outcome ~= "Escrowed" then
		local Unreachable: never = Ruling
		return false, Unreachable, nil
	end

	local Tid, Hold = Ruling.Tid, Ruling.Hold
	local Handed, Why = pcall(function()
		Post(Records, Format, From, Tid, Hold.To, Hold.Amount, Hold.At)
	end)
	if Handed then
		return true, nil, nil
	end

	warn(`Ledger: transfer {Tid} from {From} took the money but could not hand it over. it is set aside, and Ledger finishes or refunds it on its own: {Why}`)
	return false, Errors.Reason(Why), true
end

return table.freeze({
	Reserve = Reserve,
	Post = Post,
	Settle = Settle,
	Prune = Prune,
	Drive = Drive,
	Terms = Terms,
	LandedOn = LandedOn,
})
