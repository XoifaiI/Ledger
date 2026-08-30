--!strict
--!optimize 2

--[=[

	Booking: Holds units of a number field under a name.

	The units stay set aside until something takes them, gives them back, or hands them to another
	key. A booking runs out after its hold, and the next booking on that key gives back any that have.
	A hand over marks the booking before it reaches the receiver, so the units show on both keys
	between the two writes.

	Return type: A table with Layered, Book, Take, Sent, Free, Hand, Undo, Give, Terms, Entry, Late, Expired, Overdue, Owed, Granted, Delivered and the four ids.
	Example usage:
		local Booking = require("./Booking")
		local Op = Booking.Book("order1", "Stock", 1)
--]=]

local TableUtil = require("../Util/TableUtil")
local Clock = require("../Util/Clock")
local Errors = require("../Core/Errors")
local Windows = require("../Core/Constants/Windows")
local Sizes = require("../Core/Constants/Sizes")
local Fingerprint = require("../Encode/Fingerprint")
local Validate = require("../Core/Validate")
local Applied = require("../Core/Applied")
local Layer = require("./Layer")
local Shapes = require("../Core/Shapes")

type Op = Shapes.Op
type Data = Shapes.Folded
type Kept = { [string]: Shapes.Booked }

local BOOK = "__Book"
local TAKE = "__Take"
local SENT = "__Sent"
local FREE = "__Free"
local GIVEN = "__Given"
local HAND = "__Hand"
local UNHAND = "__Unhand"

local BOOK_ID = "bk"
local TAKE_ID = "tk"
local SENT_ID = "sn"
local FREE_ID = "fr"
local GIVEN_ID = "gv"
local HAND_ID = "hd"
local UNHAND_ID = "uh"

local function Entry(Booked: any, Rid: any): Shapes.Booked?
	if type(Booked) ~= "table" or type(Rid) ~= "string" then
		return nil
	end

	local Found = Booked[Rid]
	if type(Found) ~= "table" or type(Found.Amount) ~= "number" or type(Found.Field) ~= "string" then
		return nil
	end
	return if type(Found.At) == "number" then Found else nil
end

local function Ends(Held: Shapes.Booked): number?
	if type(Held.At) ~= "number" then
		return nil
	end

	local Hold = if type(Held.Hold) == "number" and Held.Hold > 0 then Held.Hold else Windows.BOOK
	return Held.At + Hold
end

local function Late(Held: Shapes.Booked, Now: number): boolean
	local Runs = Ends(Held)
	return Runs ~= nil and Runs < Now
end

local function Expired(Held: Shapes.Booked, Now: number): boolean
	local Runs = Ends(Held)
	return Runs ~= nil and Runs + Windows.BOOK_MARGIN < Now
end

local function Stale(Data: Data, Booked: Kept, Now: number): (Kept, { [string]: number })
	local Kept: Kept = {}
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
	local Amount = Validate.Number(Op.Amount)
	local At = Op.At
	if Amount == nil then
		return nil
	end
	if type(At) ~= "number" then
		return nil
	end

	local Rid = Op.Rid
	local Hold = Op.Hold
	local To = Op.To
	if type(Rid) ~= "string" or #Rid == 0 then
		return nil
	end
	if Hold ~= nil and type(Hold) ~= "number" then
		return nil
	end
	if To ~= nil and type(To) ~= "string" then
		return nil
	end

	local Booked = Data._Booked or {}
	if Booked[Rid] ~= nil then
		return nil
	end

	local Kept, Back = Stale(Data, Booked, At)
	if TableUtil.Count(Kept) >= Sizes.Booked then
		return nil
	end

	local Next = table.clone(Data)
	for Name, Given in Back do
		Next[Name] += Given
	end

	if Next[Field] < Amount then
		return nil
	end
	Next[Field] -= Amount

	Kept[Rid] = { Field = Field, Amount = Amount, At = At, Hold = Hold, To = To }
	Next._Booked = TableUtil.Some(Kept)

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
		Errors.Broke(`giving booking {tostring(Op.Rid)} back left less of '{Held.Field}' than it started with`)
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
	if not Validate.Positive(Op.Amount) then
		return nil
	end

	local Rid = Op.Rid
	if type(Rid) ~= "string" then
		return nil
	end

	if type(Op.At) ~= "number" then
		return nil
	end

	local Print = if type(Op.Print) == "string" then Op.Print else nil
	local Received = (Data._Received or {}) :: { [string]: any }
	if Applied.Has(Received, Applied.GRANT, Rid) then
		return nil
	end

	local Next = table.clone(Data)
	Next[Field] = Data[Field] + Op.Amount
	Next._Received = Applied.Remember(Received, Applied.Key(Applied.GRANT, Rid), Op.At, Print)

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
		To = To,
	} :: any
end

local function Named(Prefix: string, Kind: string, Rid: string): Op
	return { Id = `{Prefix}:{Rid}`, Kind = Kind, Rid = Rid, At = Clock.Now() } :: any
end

local function Take(Rid: string): Op
	return Named(TAKE_ID, TAKE, Rid)
end

local function Sent(Rid: string): Op
	return Named(SENT_ID, SENT, Rid)
end

local function Free(Rid: string): Op
	return Named(FREE_ID, FREE, Rid)
end

local function Hand(Rid: string): Op
	return Named(HAND_ID, HAND, Rid)
end

local function Undo(Rid: string): Op
	return Named(UNHAND_ID, UNHAND, Rid)
end

local function Give(Rid: string, Field: string, Amount: number, Print: string?): Op
	return { Id = `{GIVEN_ID}:{Rid}`, Kind = GIVEN, Rid = Rid, Field = Field, Amount = Amount, At = Clock.Now(), Print = Print } :: any
end

local function Terms(From: string, Rid: string, Held: Shapes.Booked): string
	return Fingerprint.Of(Fingerprint.Canon({
		From = From,
		Rid = Rid,
		Field = tostring(Held.Field),
		Amount = Held.Amount,
		At = Held.At,
	}))
end

local function Granted(State: any, Rid: string, Print: string?): Applied.Recalled
	return Applied.Recall(State._Received, Applied.GRANT, Rid, Print)
end

local function Delivered(State: any, Rid: string): boolean
	return Applied.Has(State._Received, Applied.GRANT, Rid)
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
		[SENT] = Taking,
		[FREE] = Freeing,
		[GIVEN] = Giving,
		[HAND] = Handing,
		[UNHAND] = Unhanding,
	},
	Owns = {
		{ Field = "_Booked", Says = "the units set aside" },
	},
}

local function Layered(_Balance: string?): Layer.Layer?
	return Held
end

return table.freeze({
	Layered = Layered,

	Book = Book,
	Take = Take,
	Sent = Sent,
	Free = Free,
	Hand = Hand,
	Undo = Undo,
	Give = Give,
	Terms = Terms,
	Entry = Entry,
	Late = Late,
	Expired = Expired,
	Overdue = Overdue,
	Owed = Owed,
	Granted = Granted,
	Delivered = Delivered,
	FREE_ID = FREE_ID,
	SENT_ID = SENT_ID,
	HAND_ID = HAND_ID,
	UNHAND_ID = UNHAND_ID,
})
