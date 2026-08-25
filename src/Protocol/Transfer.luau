--!strict
--!optimize 2

--[=[
	Transfer: Moves a balance across two keys in three legs.

	The legs are reserve, deliver and settle. Each leg is atomic on its own key, and the transfer id
	makes each leg apply one time.
	The order matters. The money arrives first, and the hold on the sender clears second. The other
	order would destroy the money if a server stopped between the two.
	A server that stops leaves the money set aside, and recovery finishes it or gives it back.
	Post reads the applied name back out of the state, because an op sits in the log whether or not
	the reducer took it.

	Return type: A table with Reserve, Post, Settle, Prune, Drive, Terms, Older and LandedOn.
	Example usage:
		local Transfer = require("./Transfer")
		local Ok, Why = Transfer.Drive(Books, Format, "a", "b", 30, "tip1")
--]=]

local Say = require("../Util/Say")
local Clock = require("../Util/Clock")
local Fault = require("../Contract/Fault")
local Reasons = require("../Contract/Reason")
local Contract = require("../Contract/Op")
local Entries = require("../Kernel/Entries")
local Fingerprint = require("../Encode/Fingerprint")
local Ident = require("../Encode/Ident")
local Log = require("../Record/Log")
local LogTypes = require("../Record/Types")
local Stamp = require("../Record/Stamp")
local Step = require("../Record/Step")
local Shape = require("../Record/Shape")
local Escrow = require("../Feature/Escrow")

type Op = Contract.Op
type Record = Contract.Record<any>
type Reason = Reasons.Reason
type Log = LogTypes.Log
type Format = LogTypes.Shape<any>

export type Hold = { To: number | string, Amount: number, At: number }

export type Reserved = { read Outcome: "Finished" } | { read Outcome: "Escrowed", read Tid: string, read Hold: Hold } | { read Outcome: "Stopped", read Why: Reason }

local REFUSED = Reasons.Refused
local BUSY = Reasons.Busy
local SPENT = Reasons.Spent
local HELD = Reasons.Held

local function Terms(From: number | string, To: number | string, Amount: number): string
	return Fingerprint.Of(Fingerprint.Canon({ From = tostring(From), To = tostring(To), Amount = Amount }))
end

local function Older(To: number | string, Amount: number): string
	return Fingerprint.Of(Fingerprint.Canon({ To = tostring(To), Amount = Amount }))
end

local function LandedOn(Format: Format, Record: Record, Tid: string, Print: string?, Before: string?, From: (number | string)?): Entries.Recalled
	local Held, Meant, Sender = Stamp.Written(Record, `{Escrow.DELIVER_ID}:{Tid}`)
	if Held and Print ~= nil and Sender ~= nil and From ~= nil and tostring(Sender) ~= tostring(From) then
		return Entries.OTHER
	end

	if Held and Meant ~= nil and Print ~= nil then
		return if Meant == Print or Meant == Before then Entries.SAME else Entries.OTHER
	end

	if Held and Print == nil then
		return Entries.SAME
	end

	local State: any = Format:Fold(Record)
	local Recalled = Entries.Recall(State._Received, Entries.TRANSFER, Tid, Print)
	if Recalled == Entries.OTHER and Before ~= nil then
		return Entries.Recall(State._Received, Entries.TRANSFER, Tid, Before)
	end
	return Recalled
end

local function Delivered(Records: Log, Format: Format, To: number | string, Tid: string, Print: string?, Before: string?, From: (number | string)?): Entries.Recalled
	return LandedOn(Format, Records:Read(tostring(To)), Tid, Print, Before, From)
end

local function Reserve(Records: Log, Format: Format, From: number | string, To: number | string, Amount: number, Id: string?): Reserved
	if not (type(Amount) == "number" and Amount > 0 and Amount < math.huge) then
		return { Outcome = "Stopped", Why = REFUSED }
	end

	local Tid = Id or Ident.Fresh()
	local Print = Terms(From, To, Amount)
	local Before = Older(To, Amount)

	if Id ~= nil then
		local Already = Delivered(Records, Format, To, Tid, Print, Before, From)
		if Already == Entries.SAME then
			return { Outcome = "Finished" }
		end
		if Already == Entries.OTHER then
			Say.Warn(`Ledger: transfer {Tid} already went through for a different amount or a different key, and a name has to mean the same thing every time. nothing was sent, so pick a new name`)
			return { Outcome = "Stopped", Why = SPENT }
		end
	end

	local ReserveOp: Op = { Id = `{Escrow.RESERVE_ID}:{Tid}`, Kind = Escrow.RESERVE, To = To, Amount = Amount, Tid = Tid, At = Clock.Now() }

	local Record = Records:Append(tostring(From), { ReserveOp }, function(Stored: Record): boolean
		if Stamp.HasPending(Stored) then
			return false
		end
		return Step(Format.Reducer, Format:Fold(Shape.Detached(Stored)), ReserveOp) ~= nil
	end)
	local State = Format:Fold(Record)

	local Holds: any = State._Held
	local Escrowed: Hold? = if type(Holds) == "table" then Holds[Tid] else nil
	if Escrowed ~= nil then
		if Escrowed.To ~= To or Escrowed.Amount ~= Amount then
			Say.Warn(`Ledger: transfer {Tid} already has {Escrowed.Amount} set aside for {Escrowed.To}, so that is what it pays out, not the {Amount} to {To} you just asked for`)
		end

		local At = Escrowed.At
		if type(At) == "number" and Clock.Now() - At > Escrow.REDRIVE_HORIZON then
			Say.Warn(
				`Ledger: transfer {Tid} from {From} has been set aside longer than Ledger sends one again, so recovery owns it now and this call left it alone. it is finished or given back on its own`
			)
			return { Outcome = "Stopped", Why = HELD }
		end

		return { Outcome = "Escrowed", Tid = Tid, Hold = Escrowed }
	end

	local Spend = Entries.Recall((State :: any)._Received, Entries.SENT, Tid, Print)
	if Spend == Entries.OTHER then
		Spend = Entries.Recall((State :: any)._Received, Entries.SENT, Tid, Before)
	end
	if Spend == Entries.OTHER then
		Say.Warn(`Ledger: transfer {Tid} already went through for a different amount or a different key, and a name has to mean the same thing every time. nothing was sent, so pick a new name`)
		return { Outcome = "Stopped", Why = SPENT }
	end
	if Spend == Entries.SAME or Stamp.Carries(Record, `{Escrow.SETTLE_ID}:{Tid}`) then
		return { Outcome = "Finished" }
	end
	if Stamp.Carries(Record, `{Escrow.EXPIRE_ID}:{Tid}`) then
		return { Outcome = "Stopped", Why = SPENT }
	end
	if Stamp.HasPending(Record) then
		return { Outcome = "Stopped", Why = BUSY }
	end

	return { Outcome = "Stopped", Why = REFUSED }
end

local function Settle(Records: Log, From: number | string, Tid: string, Print: string?): Record
	local SettleOp: Op = { Id = `{Escrow.SETTLE_ID}:{Tid}`, Kind = Escrow.SETTLE, Tid = Tid, At = Clock.Now(), Print = Print }
	return (Records:Append(tostring(From), { SettleOp }))
end

local function Post(Records: Log, Format: Format, From: number | string, Tid: string, To: number | string, Amount: number)
	Fault.Holds(tostring(From) ~= tostring(To), `transfer {Tid} is being delivered to the key it came from, so the money would be counted twice`)
	Fault.Holds(Amount > 0, `transfer {Tid} is being delivered with nothing in it`)

	local Print = Terms(From, To, Amount)
	local DeliverOp: Op = { Id = `{Escrow.DELIVER_ID}:{Tid}`, Kind = Escrow.DELIVER, From = From, Amount = Amount, Tid = Tid, At = Clock.Now(), Print = Print }
	local Landed = Records:Append(tostring(To), { DeliverOp }, Log.NotEntombed)
	if not Stamp.Carries(Landed, DeliverOp.Id) then
		error(Fault.New(HELD, `'{To}' was erased, so transfer {Tid} cannot be delivered. the {Amount} has already left '{From}' and stays set aside until it is given back`))
	end

	local Landing = LandedOn(Format, Landed, Tid, DeliverOp.Print, Older(To, Amount), From)
	if Landing == Entries.OTHER then
		error(
			Fault.New(
				SPENT,
				`transfer {Tid} cannot be delivered to '{To}', a different transfer already went through under that name. the {Amount} stays set aside on '{From}' until it is given back, and a transfer name belongs to one sender`
			)
		)
	end
	if Landing == Entries.UNSEEN then
		error(
			Fault.New(
				HELD,
				`transfer {Tid} cannot be shown to have reached '{To}'. its delivery was folded into the snapshot and the name has aged out, so the {Amount} stays set aside on '{From}' rather than settle against a delivery that may belong to someone else`
			)
		)
	end

	local Cleared = Settle(Records, From, Tid, Print)
	Fault.Holds(
		Entries.Has((Format:Fold(Cleared) :: any)._Received, Entries.SENT, Tid),
		`transfer {Tid} was delivered to '{To}' but the hold on '{From}' was not settled, so the money is on both keys`
	)

	Records:Trim(tostring(To), Format, Landed)
	Records:Trim(tostring(From), Format, Cleared)
end

local function Prune(Records: Log, UserId: number | string)
	local PruneOp: Op = { Id = `{Escrow.PRUNE_ID}:{Ident.Fresh()}`, Kind = Escrow.PRUNE, At = Clock.Now() }
	Records:Append(tostring(UserId), { PruneOp })
end

local function Drive(Records: Log, Format: Format, From: number | string, To: number | string, Amount: number, Id: string?): (boolean, Reason?, boolean?)
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
	if Ruling.Outcome ~= "Escrowed" then
		local Unreachable: never = Ruling
		return false, Unreachable, nil
	end

	local Tid, Hold = Ruling.Tid, Ruling.Hold
	local Handed, Why = pcall(function()
		Post(Records, Format, From, Tid, Hold.To, Hold.Amount)
	end)
	if Handed then
		return true, nil, nil
	end

	Say.Warn(`Ledger: transfer {Tid} from {From} took the money but could not hand it over. it is set aside, and Ledger finishes or refunds it on its own: {Why}`)
	return false, Fault.Named(Why), true
end

return table.freeze({
	Reserve = Reserve,
	Post = Post,
	Settle = Settle,
	Prune = Prune,
	Drive = Drive,
	Terms = Terms,
	Older = Older,
	LandedOn = LandedOn,
})
