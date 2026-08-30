--!strict
--!optimize 2

--[=[

	Recovery: Picks up the work a server left when it stopped.

	Transfers sends a held transfer again while it is still worth sending, gives it back once it is
	past its window, and writes it off past the prune window with a warning naming the amount and the
	key. Bookings settles or returns a reservation past its hold. Each pass takes a fixed bite and
	leaves the rest for the next one.

	Return type: A table with Transfers, Bookings and PASS_LIMIT.
	Example usage:
		local Recovery = require("./Recovery")
		local Clean, Moved = Recovery.Transfers(Books, Format, "a", Held)
--]=]

local Clock = require("../Util/Clock")
local Errors = require("../Core/Errors")
local Windows = require("../Core/Constants/Windows")
local Shapes = require("../Core/Shapes")
local Applied = require("../Core/Applied")
local LogTypes = require("../Record/Types")
local Booking = require("../Layers/Booking")
local Escrow = require("../Layers/Escrow")
local Transfer = require("./Transfer")

type Op = Shapes.Op
type Log = LogTypes.Log
type Format = LogTypes.Shape<any>

local PASS_LIMIT = Windows.PASS_LIMIT

local function Expire(Records: Log, Format: Format, From: number | string, Tid: string, Entry: any, Age: number?)
	local Print = Transfer.Terms(From, Entry.To, Entry.Amount)
	if Transfer.LandedOn(Format, Records:Read(tostring(Entry.To)), Tid, Print, From) == Applied.SAME then
		Transfer.Settle(Records, From, Tid, Print)
		return
	end

	if Age == nil or Age <= Windows.PRUNE then
		local ExpireOp: Op = { Id = `{Escrow.EXPIRE_ID}:{Tid}`, Kind = Escrow.EXPIRE, Tid = Tid }
		Records:Append(tostring(From), { ExpireOp })
		return
	end

	warn(
		`Ledger: transfer {Tid} from {From} has been stuck over {Windows.PRUNE // 86400} days and the receiver has no record of it. a refund could pay them twice, so it is written off. check the audit log and pay {Entry.Amount} back by hand if it never arrived`
	)
	Transfer.Settle(Records, From, Tid, Print)
end

local function Redeliver(Records: Log, Format: Format, From: number | string, Tid: string, Entry: any): boolean
	local Ok, Reason = pcall(function()
		Transfer.Post(Records, Format, From, Tid, Entry.To, Entry.Amount, Entry.At)
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

local function Transfers(Records: Log, Format: Format, From: number | string, Held: any, Going: boolean?): (boolean, boolean)
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
		local Overdue = Age == nil or Age > Windows.REDRIVE + Windows.EXPIRE_MARGIN
		local Fresh = if Going then not Overdue else Age ~= nil and Age <= Windows.REDRIVE
		Errors.Holds(not (Fresh and Overdue), `transfer {Tid} counts as both still worth sending and long overdue, so recovery cannot tell whether to deliver it or give it back`)

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

	Errors.Holds(Handled <= PASS_LIMIT, "one recovery pass took on more holds than its own limit allows")
	Errors.Holds(Moved + Failures == Handled, "a recovery pass neither finished nor failed one of the holds it took on")
	return Failures == 0 and Waiting == 0 and Resting == 0, Moved > 0 or Resting > 0
end

local function Unreadable(Booked: any, Key: string)
	if type(Booked) ~= "table" then
		return
	end

	for Rid in Booked do
		if Booking.Entry(Booked, Rid) ~= nil then
			continue
		end
		warn(
			`Ledger: '{Key}' holds a reservation named '{tostring(Rid)}' that Ledger cannot read. nothing will ever settle it and its units stay out of circulation. check the audit log and put them back by hand`
		)
	end
end

local function Bookings(Records: Log, Format: Format, Key: string, State: any, Read: (string) -> any): boolean
	local Now = Clock.Now()
	local Booked = (State :: any)._Booked
	Unreadable(Booked, Key)

	local Late = Booking.Overdue(State, Now)
	if #Late == 0 then
		return false
	end
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

		local Fine, Ruling = pcall(function(): Applied.Recalled
			return Booking.Granted(Read(To :: string), Rid, Booking.Terms(Key, Rid, Held :: any))
		end)
		if not Fine then
			warn(`Ledger: could not check '{To}' before giving back booking {Rid}, so it waits for the next pass`)
			continue
		end
		if Ruling == Applied.SAME then
			table.insert(Ops, Booking.Take(Rid))
			continue
		end
		if Ruling == Applied.OTHER then
			warn(`Ledger: '{To}' holds a booking named {Rid} that came from somewhere else, so this one never arrived. its units go back to '{Key}'`)
			table.insert(Ops, Booking.Undo(Rid))
			continue
		end

		local At = if Held ~= nil then Held.At else nil
		if Held ~= nil and Held.Handing == true and type(At) == "number" and Now - At > Windows.PRUNE then
			warn(
				`Ledger: booking {Rid} on '{Key}' has been open over {Windows.PRUNE // 86400} days and '{To}' has no record of it. giving it back could pay twice, so it is written off. check the audit log and give the {Held.Amount} of '{Held.Field}' back by hand if it never arrived`
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
