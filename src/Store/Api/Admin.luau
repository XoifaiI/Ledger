--!strict
--!optimize 2

--[=[

	Admin: The operator side of a store.

	Resettle and RecoverTransfers finish what a stopped server left, ClearDelivered prunes applied
	names, Reset puts a key back to the default state, and Erase buries it. These are the only paths
	that throw data away, so each says what went with it. The first erase leaves a tombstone, and only
	an erase that finds an old one removes the key.

	Return type: A table with Failed. It writes Freed, Repair, ReapMarkers, Buried, HeldOn, HandOver, HandBooked, Resettle, RecoverTransfers, ClearDelivered, Reset and Erase onto the class.
	Example usage:
		local Admin = require("./Admin")
		local Ok, Why = self:Erase(1):Wait()
--]=]

local Future = require("../../Util/Future")
local TableUtil = require("../../Util/TableUtil")
local Clock = require("../../Util/Clock")
local Windows = require("../../Core/Constants/Windows")
local Errors = require("../../Core/Errors")
local Reasons = require("../../Core/Constants/Reasons")
local Shapes = require("../../Core/Shapes")
local Compact = require("../../Record/Compact")
local Log = require("../../Record/Log")
local NewOp = require("../../Record/NewOp")
local Schema = require("../../Record/Schema")
local TxStamp = require("../../Record/TxStamp")
local Kinds = require("../../Core/Constants/Kinds")
local Booking = require("../../Layers/Booking")
local Recovery = require("../../Protocol/Recovery")
local Transfer = require("../../Protocol/Transfer")
local Transactions = require("../../Core/Constants/Transactions")
local Tx = require("../../Protocol/Tx")
local Registry = require("../Registry")
local Write = require("./Write")
local Store = require("../Class")
local Types = require("../Types")

type Future<T...> = Future.Future<T...>
type Record = Shapes.Record<any>
type KeyLike = Shapes.KeyLike
type Reason = Reasons.Reason
type Store = Types.Store<any>

local Players = game:GetService("Players")

local BUSY = Reasons.Busy
local BEHIND = Reasons.Behind

local Failed = Write.Failed

local function Aside(Booked: any): (number, { [string]: number })
	local Fields: { [string]: number } = {}
	local Count = 0
	if type(Booked) ~= "table" then
		return Count, Fields
	end

	for Rid in Booked do
		local Entry = Booking.Entry(Booked, Rid)
		if Entry ~= nil then
			Fields[Entry.Field] = (Fields[Entry.Field] or 0) + Entry.Amount
			Count += 1
		end
	end
	return Count, Fields
end

function Store.Freed(self: Store, Key: string, State: any): boolean
	return Recovery.Bookings(self:Records(), self:Format(), Key, State, function(To: string): any
		return self:Fold(self:ReadRecord(To))
	end)
end

function Store.Repair(self: Store, Key: string): (boolean, boolean)
	local Record = Tx.Settle(self:Records(), self.TxWrapper, Key, self:ReadRecord(Key))
	if TxStamp.HasPending(Record) then
		return false, false
	end

	local State = self:Fold(Record)
	local Gave = self:Freed(Key, State)
	local Waiting = TableUtil.Occupied(State._Booked)

	local Held = State._Held
	if not TableUtil.Occupied(Held) then
		return not Waiting, Gave or Waiting
	end

	local Clean, Moved = Recovery.Transfers(self:Records(), self:Format(), Key, Held)
	return Clean and not Waiting, Moved or Gave or Waiting
end

function Store.ReapMarkers(self: Store): number
	local Name = self.Wrapper.Name
	local Reads = Enum.DataStoreRequestType.GetAsync

	local Ok, Reaped, Next = pcall(function(): (number, number)
		return Tx.Reap(self.TxWrapper, function(Store: string): Log.Log?
			for _, Known in Registry.Stores do
				if Known.Wrapper.Name == Store then
					return Known:Records()
				end
			end
			return nil
		end, {
			Node = self.Node,
			From = self.Resume,
			Afford = function(): boolean
				return self:TxAffords(Reads, Transactions.REAP_FLOOR) and self:Affords(Reads, Transactions.REAP_FLOOR)
			end,
		})
	end)
	if Ok then
		self.Resume = Next
		return Reaped
	end

	warn(`Ledger: could not tidy up the transaction markers for '{Name}', so they wait for the next pass: {Reaped}`)
	return 0
end

function Store.Buried(self: Store, Key: string, Replaced: Record)
	local Ok, State = pcall(function(): any
		return self:Fold(Schema.Detached(Replaced))
	end)
	if not Ok then
		warn(`Ledger: erased '{Key}' but could not read back what was on it, so this cannot say what went with it: {State}`)
		return
	end
	if type(State) ~= "table" then
		return
	end

	local Count, Fields = Aside(State._Booked)
	for Named, Amount in Fields do
		warn(`Ledger: erasing '{Key}' destroyed {Count} reservation(s) holding {Amount} {Named}. anything already handed to another key stays there, and nothing else is given back`)
	end

	local Field = self.Options.Balance
	if Field == nil then
		return
	end

	local Balance = State[Field]
	if type(Balance) ~= "number" or Balance <= 0 then
		return
	end

	warn(`Ledger: erasing '{Key}' destroyed {Balance} {Field}. anything sent to it for the next {Windows.TOMB // 86400} days is turned away and given back to whoever sent it`)
end

function Store.HeldOn(self: Store, Key: string): (boolean, any)
	return pcall(function(): any
		return self:Fold(self:ReadRecord(Key))._Held
	end)
end

local function CountHeld(Held: any): (number, number)
	if type(Held) ~= "table" then
		return 0, 0
	end

	local Holds, Amount = 0, 0
	for _, Entry in Held do
		if type(Entry) == "table" and type(Entry.Amount) == "number" then
			Holds += 1
			Amount += Entry.Amount
		end
	end
	return Holds, Amount
end

function Store.HandOver(self: Store, Key: string): (number, number)
	local Read, Held = self:HeldOn(Key)
	if not Read then
		warn(`Ledger: could not check '{Key}' for unfinished transfers before erasing it, so any money still being sent is gone for good: {Held}`)
		return 0, 0
	end
	if not TableUtil.Occupied(Held) then
		return 0, 0
	end

	local Sent, Why = pcall(function()
		Recovery.Transfers(self:Records(), self:Format(), Key, Held, true)
	end)
	if not Sent then
		warn(`Ledger: could not hand over the transfers set aside on '{Key}' before erasing it, they are counted below: {Why}`)
	end

	local Again, Left = self:HeldOn(Key)
	if not Again then
		warn(`Ledger: could not check '{Key}' again after finishing its transfers, so anything still being sent is gone for good: {Left}`)
		return 0, 0
	end
	return CountHeld(Left)
end

function Store.HandBooked(self: Store, Key: string)
	local Read, State = pcall(function(): any
		return self:Fold(self:ReadRecord(Key))
	end)
	if not Read or type(State) ~= "table" then
		warn(`Ledger: could not check '{Key}' for units set aside for another key before erasing it, so any that were owed go with it: {State}`)
		return
	end

	local Booked = State._Booked
	if not TableUtil.Occupied(Booked) then
		return
	end

	for Rid in Booked do
		local Held = Booking.Entry(Booked, Rid)
		if Held == nil or type(Held.To) ~= "string" then
			continue
		end

		local Gave, Moved = pcall(function(): boolean
			return self:Handed(Key, Rid, Held)
		end)
		if Gave and Moved then
			continue
		end

		local Says = if Gave then "the booking could not be marked as leaving" else tostring(Moved)
		warn(`Ledger: could not hand booking '{Rid}' on '{Key}' over to '{Held.To}' before erasing it, so its {Held.Amount} {Held.Field} goes with the key: {Says}`)
	end
end

function Store.Resettle(self: Store, Key: KeyLike): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Resettle")

	return Future.New(function(): (boolean, Reason?)
		local Ok, Clean = pcall(function(): boolean
			return (self:Repair(Resolved))
		end)
		if not Ok then
			return false, Failed("finish what is unsettled on", Resolved, Clean)
		end
		return Clean, if Clean then nil else BUSY
	end)
end

function Store.RecoverTransfers(self: Store, Key: KeyLike): Future<boolean, Reason?>
	self:ExpectBalance("RecoverTransfers")
	local Resolved = self:Resolve(Key, "RecoverTransfers")

	return Future.New(function(): (boolean, Reason?)
		local Ok, Clean = pcall(function(): boolean
			local Held = self:Fold(self:ReadRecord(Resolved))._Held
			return (Recovery.Transfers(self:Records(), self:Format(), Resolved, Held))
		end)
		if not Ok then
			return false, Failed("recover the transfers set aside on", Resolved, Clean)
		end
		return Clean, if Clean then nil else BUSY
	end)
end

function Store.ClearDelivered(self: Store, Key: KeyLike): Future<boolean, Reason?>
	self:ExpectBalance("ClearDelivered")
	local Resolved = self:Resolve(Key, "ClearDelivered")

	return Future.New(function(): (boolean, Reason?)
		local Ok, Why = pcall(function()
			Transfer.Prune(self:Records(), Resolved)
		end)
		if not Ok then
			return false, Failed("clear the delivered transfers on", Resolved, Why)
		end
		return true, nil
	end)
end

function Store.Reset(self: Store, Key: KeyLike): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Reset")

	local Steps = self.Migrations
	local Known = #Steps
	local Op = NewOp.New(Kinds.RESET, { State = self.Initial, Version = Known, Floor = Schema.FloorOf(Steps) })

	return Future.New(function(): (boolean, Reason?)
		local Looked, Before = pcall(function(): any
			return self:Fold(self:ReadRecord(Resolved))
		end)
		local Dropping: any = if Looked and type(Before) == "table" then Before._Booked else nil

		local Ok, Why = self:Written(Resolved, Op, "reset", function(Record: Record): boolean
			if TxStamp.HasPending(Record) then
				Errors.Raise(BUSY, `'{Resolved}' has a transaction parked on it, so a reset now would overwrite a leg the transaction still counts as committed`)
			end

			if Booking.Owed(self:Fold(Record)._Booked) then
				Errors.Raise(BUSY, `'{Resolved}' has units set aside for another key, so a reset now could leave them on both. hand them over or release them first`)
			end
			return (Record.Version or 0) <= Known
		end, BEHIND)

		if Ok then
			local Count, Fields = Aside(Dropping)
			for Named, Amount in Fields do
				warn(
					`Ledger: resetting '{Resolved}' destroyed {Count} reservation(s) holding {Amount} {Named}. Confirm and Release on those ids are refused from here on, so tell whoever is holding them`
				)
			end

			local Read, Held = pcall(function(): string?
				return Compact.Blocked(self:ReadRecord(Resolved), self:Format())
			end)
			if Read and Held ~= nil then
				warn(
					`Ledger: '{Resolved}' was reset but its oldest op is still a '{Held}' this build does not apply, so the log cannot be compacted and the key stops taking writes once it fills up. a reset cannot clear that, only a build that applies '{Held}' or erasing the key can`
				)
			end
		end
		return Ok, Why
	end)
end

function Store.Erase(self: Store, Key: KeyLike): Future<boolean, Reason?>
	local Resolved = self:Resolve(Key, "Erase")

	if self.Keys == "Player" and Players:GetPlayerByUserId(tonumber(Resolved) or 0) ~= nil then
		warn(`Ledger: erasing {Resolved} while they are still in this server, so their session writes part of the record back`)
	end

	return Future.New(function(): (boolean, Reason?)
		local Holds, Amount = 0, 0
		if self.Options.Balance then
			Holds, Amount = self:HandOver(Resolved)
		end
		self:HandBooked(Resolved)

		local Steps = self.Migrations
		local Ok, Replaced = pcall(function(): Record
			return self:Records():Entomb(Resolved, Clock.Now(), function(Record: Record): Record
				local Fine, State = pcall(function(): any
					return self:Fold(Record)
				end)

				local Names = if Fine and type(State) == "table" then State._Received else nil
				if type(Names) ~= "table" or next(Names) == nil then
					return { Ops = {}, Seen = {} }
				end

				local Fresh: any = TableUtil.DeepCopy(self.Initial)
				Fresh._Received = TableUtil.DeepCopy(Names)
				return {
					Ops = {},
					Seen = {},
					Snapshot = Fresh,
					Version = #Steps,
					Floor = Schema.FloorOf(Steps),
				}
			end)
		end)

		if not Ok then
			return false, Failed("erase", Resolved, Replaced)
		end

		if Holds > 0 then
			warn(`Ledger: erased '{Resolved}' while {Holds} transfer(s) worth {Amount} had not finished, so that money is gone for good. check the audit log and pay the receivers back by hand`)
		end

		local Before = Replaced :: Record
		self:Buried(Resolved, Before)

		if Before.Erased ~= nil and not Log.Entombed(Before) then
			local Reached, Gone, Cause = pcall(function(): (boolean, any)
				return self.Wrapper:RemoveAsync(Resolved)
			end)
			if not (Reached and Gone) then
				Failed("take the old record off the datastore for", Resolved, if Reached then Cause else Gone)
			end
		end
		return true, nil
	end)
end

return table.freeze({})
