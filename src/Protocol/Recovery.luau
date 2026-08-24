--!strict
--!optimize 2

--[=[
	Recovery: Picks up the work that a server left when it stopped.

	A transfer that is still worth sending is sent again. A transfer that is past its window is
	given back. A reservation that is past its hold is settled or returned.
	Each pass has a limit, so a key that has many stranded takes several passes and not one long one.
	A transfer that is past the prune horizon is written off, not refunded. The receiver has
	forgotten the delivery id, so a refund could pay a player two times. Ledger writes a warning
	with the amount, and a person decides. A reservation that old is written off for the same reason.
	One pass handles a fixed number of holds and a fixed number of reservations. The windows and
	that cap are in Contract/Horizons.
	A hold between the two windows is left alone on purpose, so nothing delivers it while another
	server gives it back. It still means the key is not finished, and a pass that only rested counts
	as progress, so the sweep keeps the key without spending a try on it.

	Return type: A table with Transfers, Bookings and PASS_LIMIT.
	Example usage:
		local Recovery = require("./Recovery")
		local Clean, Moved = Recovery.Transfers(Books, Format, "a", Held)
--]=]

local Clock = require("../Util/Clock")
local Fault = require("../Contract/Fault")
local Horizons = require("../Contract/Horizons")
local Contract = require("../Contract/Op")
local Entries = require("../Kernel/Entries")
local LogTypes = require("../Record/Types")
local Booking = require("../Feature/Booking")
local Escrow = require("../Feature/Escrow")
local Transfer = require("./Transfer")

type Op = Contract.Op
type Log = LogTypes.Log
type Format = LogTypes.Shape<any>

local REDRIVE_HORIZON = Horizons.REDRIVE
local EXPIRE_MARGIN = Horizons.EXPIRE_MARGIN
local PRUNE_HORIZON = Horizons.PRUNE

local PASS_LIMIT = Horizons.PASS_LIMIT

local function Expire(Records: Log, Format: Format, From: number | string, Tid: string, Entry: any, Age: number?)
	local Print = Transfer.Terms(From, Entry.To, Entry.Amount)
	local Before = Transfer.Older(Entry.To, Entry.Amount)
	if Transfer.LandedOn(Format, Records:Read(tostring(Entry.To)), Tid, Print, Before, From) == Entries.SAME then
		Transfer.Settle(Records, From, Tid, Print)
		return
	end

	if Age == nil or Age <= PRUNE_HORIZON then
		local ExpireOp: Op = { Id = `{Escrow.EXPIRE_ID}:{Tid}`, Kind = Escrow.EXPIRE, Tid = Tid }
		Records:Append(tostring(From), { ExpireOp })
		return
	end

	Fault.Holds(Age > PRUNE_HORIZON, "a transfer is being written off before it is old enough, so money would be destroyed early")

	warn(
		`Ledger: transfer {Tid} from {From} has been stuck over {PRUNE_HORIZON // 86400} days and the receiver has no record of it. a refund could pay them twice, so it is written off. check the audit log and pay {Entry.Amount} back by hand if it never arrived`
	)
	Transfer.Settle(Records, From, Tid, Transfer.Terms(From, Entry.To, Entry.Amount))
end

local function Redeliver(Records: Log, Format: Format, From: number | string, Tid: string, Entry: any): boolean
	local Ok, Reason = pcall(function()
		Transfer.Post(Records, Format, From, Tid, Entry.To, Entry.Amount)
	end)
	if not Ok then
		warn(`Ledger: could not send transfer {Tid} from {From} again. the money stays set aside and the next recovery has another go: {Reason}`)
	end
	return Ok
end

local function GiveBack(Records: Log, Format: Format, From: number | string, Tid: string, Entry: any, Age: number?): boolean
	local Ok, Reason = pcall(function()
		Expire(Records, Format, From, Tid, Entry, Age)
	end)
	if not Ok then
		warn(`Ledger: could not give back transfer {Tid} from {From}. the money stays set aside and the next recovery has another go: {Reason}`)
	end
	return Ok
end

local function Transfers(Records: Log, Format: Format, From: number | string, Held: any): (boolean, boolean)
	if type(Held) ~= "table" then
		return true, false
	end

	local Now = Clock.Now()
	local Failures, Handled, Waiting, Moved, Resting = 0, 0, 0, 0, 0

	for Tid, Entry in Held do
		if type(Entry) ~= "table" then
			continue
		end

		local Age = if type(Entry.At) == "number" then Now - Entry.At else nil
		local Fresh = Age ~= nil and Age <= REDRIVE_HORIZON
		local Overdue = Age == nil or Age > REDRIVE_HORIZON + EXPIRE_MARGIN
		Fault.Holds(not (Fresh and Overdue), `transfer {Tid} counts as both still worth sending and long overdue, so recovery cannot tell whether to deliver it or give it back`)

		if not Fresh and not Overdue then
			Resting += 1
			continue
		end

		if Handled >= PASS_LIMIT then
			Waiting += 1
			continue
		end
		Handled += 1

		local Ok = if Fresh then Redeliver(Records, Format, From, Tid, Entry) else GiveBack(Records, Format, From, Tid, Entry, Age)
		if Ok then
			Moved += 1
		else
			Failures += 1
		end
	end

	if Waiting > 0 then
		warn(`Ledger: {From} has more than {PASS_LIMIT} unfinished transfers, so {Waiting} of them wait for the next recovery`)
	end

	Fault.Holds(Handled <= PASS_LIMIT, "one recovery pass took on more holds than its own limit allows")
	Fault.Holds(Moved + Failures == Handled, "a recovery pass neither finished nor failed one of the holds it took on")
	return Failures == 0 and Waiting == 0 and Resting == 0, Moved > 0 or Resting > 0
end

local function Bookings(Records: Log, Format: Format, Key: string, State: any, Read: (string) -> any): boolean
	local Now = Clock.Now()
	local Late = Booking.Overdue(State, Now)
	if #Late == 0 then
		return false
	end

	local Booked = (State :: any)._Booked
	local Ops: { Op } = {}
	for _, Rid in Late do
		if #Ops >= PASS_LIMIT then
			warn(`Ledger: '{Key}' has more than {PASS_LIMIT} overdue reservations, so the rest wait for the next pass`)
			break
		end

		local Held = Booking.Entry(Booked, Rid)
		local To = if Held ~= nil then Held.To else nil

		if type(To) ~= "string" then
			table.insert(Ops, Booking.Undo(Rid))
			continue
		end

		local Fine, Ruling = pcall(function(): Entries.Recalled
			return Booking.Granted(Read(To :: string), Rid, Booking.Terms(Key, Rid, Held :: any))
		end)
		if not Fine then
			warn(`Ledger: could not check '{To}' before giving back booking {Rid}, so it waits for the next pass`)
			continue
		end
		if Ruling == Entries.SAME then
			table.insert(Ops, Booking.Take(Rid))
			continue
		end
		if Ruling == Entries.OTHER then
			warn(`Ledger: '{To}' holds a booking named {Rid} that came from somewhere else, so this one never arrived. its units go back to '{Key}'`)
			table.insert(Ops, Booking.Undo(Rid))
			continue
		end

		local At = if Held ~= nil then Held.At else nil
		if Held ~= nil and type(At) == "number" and Now - At > PRUNE_HORIZON then
			warn(
				`Ledger: booking {Rid} on '{Key}' has been open over {PRUNE_HORIZON // 86400} days and '{To}' has no record of it. giving it back could pay twice, so it is written off. check the audit log and give the {Held.Amount} of '{Held.Field}' back by hand if it never arrived`
			)
			table.insert(Ops, Booking.Take(Rid))
			continue
		end
		table.insert(Ops, Booking.Undo(Rid))
	end

	if #Ops == 0 then
		return false
	end

	local Gave = pcall(function()
		Records:Append(Key, Ops)
	end)
	if not Gave then
		warn(`Ledger: could not settle {#Ops} overdue reservation(s) on '{Key}', so they wait for the next pass`)
	end
	return Gave
end

return table.freeze({
	Transfers = Transfers,
	Bookings = Bookings,
	PASS_LIMIT = PASS_LIMIT,
})
