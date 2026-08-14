--!strict
--!optimize 2

--[=[
	Booking: Holds units of a number field under a name.
	
	The units stay set aside until something takes them or gives them back. Limited stock can
	therefore sit on one key, and does not need a transaction across two keys.
	The next booking on that key gives back each booking that is older than its hold.
	A field that is no longer a number has no place to put the units back, so that booking is kept.
	To drop it would take the units off the key.
	A grant carries a mark of the booking that sent it. The receiver keeps that mark. A caller can
	then tell its own grant from an earlier one that used the same name.
	A hand over marks the booking before it reaches the receiver. Give lands on the receiver before
	Take clears the sender, so between them the units are on both keys on purpose, and only recovery
	can ask the receiver which way it went. The mark is what stops Release deciding that instead, and
	giving back units the receiver already has.
	A booking that is late can no longer be handed over, and its units come back only after a margin
	past that. Nothing therefore hands the units over while something else gives them back.

	Return type: A table with Layered, Book, Take, Free, Hand, Undo, Give, Terms, Entry, Late, Overdue, Owed, Granted, Delivered, the three ids, BOOK_HORIZON and BOOK_MARGIN.
	Example usage:
		local Booking = require("./Booking")
		local Op = Booking.Book("order1", "Stock", 1)
--]=]

local TableUtil = require("../Util/TableUtil")
local Clock = require("../Util/Clock")
local Fault = require("../Contract/Fault")
local Horizons = require("../Contract/Horizons")
local Fingerprint = require("../Encode/Fingerprint")
local Entries = require("../Kernel/Entries")
local Layer = require("../Kernel/Layer")
local Op = require("../Contract/Op")

type Op = Op.Op
type Data = { [any]: any }

local BOOK = "__Book"
local TAKE = "__Take"
local FREE = "__Free"
local GIVEN = "__Given"
local HAND = "__Hand"
local UNHAND = "__Unhand"

local BOOK_ID = "bk"
local TAKE_ID = "tk"
local FREE_ID = "fr"
local GIVEN_ID = "gv"
local HAND_ID = "hd"
local UNHAND_ID = "uh"

local BOOK_HORIZON = Horizons.BOOK
local BOOK_MARGIN = Horizons.BOOK_MARGIN

local function Entry(Booked: any, Rid: any): Data?
	if type(Booked) ~= "table" or type(Rid) ~= "string" then
		return nil
	end

	local Found = Booked[Rid]
	return if type(Found) == "table" and type(Found.Amount) == "number" and type(Found.Field) == "string"
		then Found
		else nil
end

local function Ends(Held: Data): number?
	if type(Held.At) ~= "number" then
		return nil
	end

	local Hold = if type(Held.Hold) == "number" and Held.Hold > 0 then Held.Hold else BOOK_HORIZON
	return Held.At + Hold
end

local function Late(Held: Data, Now: number): boolean
	local Runs = Ends(Held)
	return Runs ~= nil and Runs < Now
end

local function Expired(Held: Data, Now: number): boolean
	local Runs = Ends(Held)
	return Runs ~= nil and Runs + BOOK_MARGIN < Now
end

local function Stale(Data: Data, Booked: Data, Now: number): (Data, { [string]: number })
	local Kept: Data = {}
	local Back: { [string]: number } = {}

	for Rid, Held in Booked do
		local Fine = Entry(Booked, Rid)
		if Fine ~= nil and not Fine.Handing and type(Data[Fine.Field]) == "number" and Expired(Fine, Now) then
			Back[Fine.Field] = (Back[Fine.Field] or 0) + Fine.Amount
		else
			Kept[Rid] = Held
		end
	end

	return Kept, Back
end

local function Booking(Data: Data, Op: Op): Data?
	local Field = Op.Field
	if type(Field) ~= "string" or type(Data[Field]) ~= "number" then
		return nil
	end
	if type(Op.Amount) ~= "number" or Op.Amount <= 0 or Op.Amount == math.huge then
		return nil
	end
	if type(Op.At) ~= "number" then
		return nil
	end

	local Booked = (Data._Booked or {}) :: Data
	if Booked[Op.Rid] ~= nil then
		return nil
	end

	local Kept, Back = Stale(Data, Booked, Op.At)

	local Next = table.clone(Data)
	for Name, Amount in Back do
		Next[Name] += Amount
	end

	if Next[Field] < Op.Amount then
		return nil
	end
	Next[Field] -= Op.Amount

	Kept[Op.Rid] = { Field = Field, Amount = Op.Amount, At = Op.At, Hold = Op.Hold, To = Op.To }
	Next._Booked = TableUtil.Some(Kept)

	if Next[Field] < 0 then
		Fault.Broke(`setting {Op.Amount} of '{Field}' aside for booking {tostring(Op.Rid)} took it below zero`)
		return nil
	end
	return Next
end

local function Taking(Data: Data, Op: Op): Data?
	local Booked = Data._Booked
	local Held = Entry(Booked, Op.Rid)
	if Held == nil then
		return nil
	end

	local Kept = table.clone(Booked :: Data)
	Kept[Op.Rid] = nil

	local Next = table.clone(Data)
	Next._Booked = TableUtil.Some(Kept)

	if TableUtil.Count(Next._Booked) ~= TableUtil.Count(Booked) - 1 then
		Fault.Broke(`taking booking {tostring(Op.Rid)} did not clear exactly the one it was held under`)
		return nil
	end
	return Next
end

local function Handing(Data: Data, Op: Op): Data?
	local Booked = Data._Booked
	local Held = Entry(Booked, Op.Rid)
	if Held == nil or Held.Handing then
		return nil
	end

	local Marked = table.clone(Held)
	Marked.Handing = true

	local Kept = table.clone(Booked :: Data)
	Kept[Op.Rid] = Marked

	local Next = table.clone(Data)
	Next._Booked = Kept
	return Next
end

local function Refund(Data: Data, Op: Op): Data?
	local Booked = Data._Booked
	local Held = Entry(Booked, Op.Rid)
	if Held == nil then
		return nil
	end
	if type(Data[Held.Field]) ~= "number" then
		return nil
	end

	local Kept = table.clone(Booked :: Data)
	Kept[Op.Rid] = nil

	local Next = table.clone(Data)
	Next[Held.Field] = Data[Held.Field] + Held.Amount
	Next._Booked = TableUtil.Some(Kept)

	if Next[Held.Field] < Data[Held.Field] then
		Fault.Broke(`giving booking {tostring(Op.Rid)} back left less of '{Held.Field}' than it started with`)
		return nil
	end
	return Next
end

local function Freeing(Data: Data, Op: Op): Data?
	local Held = Entry(Data._Booked, Op.Rid)
	if Held ~= nil and Held.Handing then
		return nil
	end
	return Refund(Data, Op)
end

local function Unhanding(Data: Data, Op: Op): Data?
	return Refund(Data, Op)
end

local function Giving(Data: Data, Op: Op): Data?
	local Field = Op.Field
	if type(Field) ~= "string" or type(Data[Field]) ~= "number" then
		return nil
	end
	if type(Op.Amount) ~= "number" or Op.Amount <= 0 or Op.Amount == math.huge then
		return nil
	end

	local Received = (Data._Received or {}) :: { [string]: any }
	if Entries.Has(Received, Entries.GRANT, Op.Rid) then
		return nil
	end

	local Next = table.clone(Data)
	Next[Field] = Data[Field] + Op.Amount
	Next._Received = Entries.Remember(Received, Entries.Key(Entries.GRANT, Op.Rid), Op.At, Op.Print)

	if not Entries.Has(Next._Received, Entries.GRANT, Op.Rid) then
		Fault.Broke(`booking {tostring(Op.Rid)} was paid in without being remembered, so it could pay again`)
		return nil
	end
	if TableUtil.Count(Next._Booked) ~= TableUtil.Count(Data._Booked) then
		Fault.Broke(`paying in booking {tostring(Op.Rid)} changed what the receiver has set aside`)
		return nil
	end
	return Next
end

local function Book(Rid: string, Field: string, Amount: number, Hold: number?, To: string?): Op
	return {
		Id = `{BOOK_ID}:{Rid}`,
		Kind = BOOK,
		Rid = Rid,
		Field = Field,
		Amount = Amount,
		At = Clock.Now(),
		Hold = Hold,
		To = To
	} :: any
end

local function Take(Rid: string): Op
	return { Id = `{TAKE_ID}:{Rid}`, Kind = TAKE, Rid = Rid, At = Clock.Now() } :: any
end

local function Free(Rid: string): Op
	return { Id = `{FREE_ID}:{Rid}`, Kind = FREE, Rid = Rid, At = Clock.Now() } :: any
end

local function Hand(Rid: string): Op
	return { Id = `{HAND_ID}:{Rid}`, Kind = HAND, Rid = Rid, At = Clock.Now() } :: any
end

local function Undo(Rid: string): Op
	return { Id = `{UNHAND_ID}:{Rid}`, Kind = UNHAND, Rid = Rid, At = Clock.Now() } :: any
end

local function Give(Rid: string, Field: string, Amount: number, Print: string?): Op
	return { Id = `{GIVEN_ID}:{Rid}`, Kind = GIVEN, Rid = Rid, Field = Field, Amount = Amount, At = Clock.Now(), Print = Print } :: any
end

local function Terms(From: string, Rid: string, Held: Data): string
	return Fingerprint.Of(Fingerprint.Canon({
		From = From,
		Rid = Rid,
		Field = tostring(Held.Field),
		Amount = Held.Amount,
		At = Held.At
	}))
end

local function Granted(State: any, Rid: string, Print: string?): Entries.Recalled
	return Entries.Recall((State :: any)._Received, Entries.GRANT, Rid, Print)
end

local function Delivered(State: any, Rid: string): boolean
	return Entries.Has((State :: any)._Received, Entries.GRANT, Rid)
end

local function Overdue(Data: Data, Now: number): { string }
	local Booked = Data._Booked
	if type(Booked) ~= "table" then
		return {}
	end

	local Late: { string } = {}
	for Rid in Booked do
		local Held = Entry(Booked, Rid)
		if Held ~= nil and Expired(Held, Now) then
			table.insert(Late, Rid)
		end
	end
	return Late
end

local function Owed(Booked: any): boolean
	if type(Booked) ~= "table" then
		return false
	end

	for _, Entry in Booked do
		if type(Entry) == "table" and type(Entry.To) == "string" then
			return true
		end
	end
	return false
end

local Held: Layer.Layer = {
	Kinds = {
		[BOOK] = Booking,
		[TAKE] = Taking,
		[FREE] = Freeing,
		[GIVEN] = Giving,
		[HAND] = Handing,
		[UNHAND] = Unhanding
	},
	Owns = {
		{ Field = "_Booked", Says = "the units set aside" }
	}
}

local function Layered(_Balance: string?): Layer.Layer?
	return Held
end

return table.freeze({
	Layered = Layered,

	Book = Book,
	Take = Take,
	Free = Free,
	Hand = Hand,
	Undo = Undo,
	Give = Give,
	Terms = Terms,
	Entry = Entry,
	Late = Late,
	Overdue = Overdue,
	Owed = Owed,
	Granted = Granted,
	Delivered = Delivered,
	FREE_ID = FREE_ID,
	HAND_ID = HAND_ID,
	UNHAND_ID = UNHAND_ID,
	BOOK_HORIZON = BOOK_HORIZON,
	BOOK_MARGIN = BOOK_MARGIN
})
