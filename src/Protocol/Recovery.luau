--!strict
--!optimize 2

--[=[

	Recovery: Picks up the work a server left when it stopped.

	Transfers sends a held transfer again while it is still worth sending. It gives one back once it
	is past its window. Past the prune window it writes one off, with a warning naming the amount, its
	field and the key. Each pass takes a fixed bite and leaves the rest for the next one.

	Return type: A table with Transfers and PASS_LIMIT.
	Example usage:
		local Recovery = require("./Recovery")
		local Clean, Moved = Recovery.Transfers(Books, Format, "a", Held)
--]=]

local Clock = require("../Util/Clock")
local Windows = require("../Core/Constants/Windows")
local Shapes = require("../Core/Shapes")
local Tags = require("../Core/Constants/Tags")
local LogTypes = require("../Record/Types")
local Kinds = require("../Core/Constants/Kinds")
local Transfer = require("./Transfer")

type Op = Shapes.Op
type Log = LogTypes.Log
type Format = LogTypes.Shape<any>

local PASS_LIMIT = Windows.PASS_LIMIT

local function Expire(Records: Log, Format: Format, From: number | string, Tid: string, Entry: any, Age: number?)
	local Print = Transfer.Terms(From, Entry.To, Entry.Amount, Entry.Field)
	if Transfer.LandedOn(Format, Records:Read(tostring(Entry.To)), Tid, Print, From) == Tags.SAME then
		Transfer.Settle(Records, From, Tid, Print)
		return
	end

	if Age == nil or Age <= Windows.PRUNE then
		local ExpireOp: Op = { Id = `{Kinds.EXPIRE_ID}:{Tid}`, Kind = Kinds.EXPIRE, Tid = Tid }
		Records:Append(tostring(From), { ExpireOp })
		return
	end

	local Lost = if type(Entry.Field) == "string" then `{Entry.Amount} {Entry.Field}` else tostring(Entry.Amount)
	warn(
		`Ledger: transfer {Tid} from {From} has been stuck over {Windows.PRUNE // Windows.DAY} days. the receiver has no record of it and giving it back could pay twice, so it is written off. check the audit log and pay {Lost} back by hand if it never arrived`
	)
	Transfer.Settle(Records, From, Tid, Print)
end

local function Redeliver(Records: Log, Format: Format, From: number | string, Tid: string, Entry: any): boolean
	local Ok, Reason = pcall(function()
		Transfer.Post(Records, Format, From, Tid, Entry.To, Entry.Amount, Entry.At, Entry.Field)
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

	return Failures == 0 and Waiting == 0 and Resting == 0, Moved > 0 or Resting > 0
end

return table.freeze({
	Transfers = Transfers,
	PASS_LIMIT = PASS_LIMIT,
})
