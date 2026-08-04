--!strict
--!optimize 2

-- units of a numeric field set aside under a name until they are taken or given back, so limited stock can be held on one key instead of locked by a transaction across two. a booking older than the horizon is given back by the next booking on that key, which is what keeps the set bounded

local Clock = require("../Clock")
local Dedupe = require("./Dedupe")
local Fault = require("../Fault")
local Types = require("../Types")

type Op = Types.Op
type Reducer<S> = Types.Reducer<S>

local BOOK = "__Book"
local TAKE = "__Take"
local FREE = "__Free"
local GIVEN = "__Given"

local BOOK_ID = "bk"
local TAKE_ID = "tk"
local FREE_ID = "fr"
local GIVEN_ID = "gv"

local BOOK_HORIZON = 15 * 60

local function Some(Entries: { [any]: any }): { [any]: any }?
	return if next(Entries) == nil then nil else Entries
end

local function Counted(Booked: any): number
	if type(Booked) ~= "table" then
		return 0
	end

	local Count = 0
	for _ in Booked do
		Count += 1
	end
	return Count
end

local function Entry(Booked: any, Rid: any): { [any]: any }?
	if type(Booked) ~= "table" or type(Rid) ~= "string" then
		return nil
	end

	local Found = Booked[Rid]
	return if type(Found) == "table" and type(Found.Amount) == "number" and type(Found.Field) == "string"
		then Found
		else nil
end

local function Expired(Held: { [any]: any }, Now: number): boolean
	if type(Held.At) ~= "number" then
		return false
	end

	local Hold = if type(Held.Hold) == "number" and Held.Hold > 0 then Held.Hold else BOOK_HORIZON
	return Held.At + Hold < Now
end

local function Stale(Data: { [any]: any }, Booked: { [any]: any }, Now: number): ({ [any]: any }, { [string]: number })
	local Kept: { [any]: any } = {}
	local Back: { [string]: number } = {}

	for Rid, Held in Booked do
		local Fine = Entry(Booked, Rid)
		-- a field that is no longer a number has nowhere to put the units back, so the booking is
		-- kept rather than cleared. dropping it would take them out of the key altogether
		local Giveable = Fine ~= nil and type(Data[Fine.Field]) == "number"

		if Giveable and Expired(Fine :: { [any]: any }, Now) then
			local Named = (Fine :: { [any]: any }).Field
			Back[Named] = (Back[Named] or 0) + (Fine :: { [any]: any }).Amount
		else
			Kept[Rid] = Held
		end
	end

	return Kept, Back
end

local function Booking(Data: { [any]: any }, Op: Op): { [any]: any }?
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

	local Booked = (Data._Booked or {}) :: { [any]: any }
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
	Next._Booked = Some(Kept)

	if Next[Field] < 0 then
		Fault.Broke(`setting {Op.Amount} of '{Field}' aside for booking {tostring(Op.Rid)} took it below zero`)
		return nil
	end
	return Next
end

local function Taking(Data: { [any]: any }, Op: Op): { [any]: any }?
	local Booked = Data._Booked
	local Held = Entry(Booked, Op.Rid)
	if Held == nil then
		return nil
	end

	local Kept = table.clone(Booked :: { [any]: any })
	Kept[Op.Rid] = nil

	local Next = table.clone(Data)
	Next._Booked = Some(Kept)

	if Counted(Next._Booked) ~= Counted(Booked) - 1 then
		Fault.Broke(`taking booking {tostring(Op.Rid)} did not clear exactly the one it was held under`)
		return nil
	end
	return Next
end

local function Freeing(Data: { [any]: any }, Op: Op): { [any]: any }?
	local Booked = Data._Booked
	local Held = Entry(Booked, Op.Rid)
	if Held == nil then
		return nil
	end
	if type(Data[Held.Field]) ~= "number" then
		return nil
	end

	local Kept = table.clone(Booked :: { [any]: any })
	Kept[Op.Rid] = nil

	local Next = table.clone(Data)
	Next[Held.Field] = Data[Held.Field] + Held.Amount
	Next._Booked = Some(Kept)

	if Next[Held.Field] < Data[Held.Field] then
		Fault.Broke(`giving booking {tostring(Op.Rid)} back left less of '{Held.Field}' than it started with`)
		return nil
	end
	return Next
end

local function Giving(Data: { [any]: any }, Op: Op): { [any]: any }?
	local Field = Op.Field
	if type(Field) ~= "string" or type(Data[Field]) ~= "number" then
		return nil
	end
	if type(Op.Amount) ~= "number" or Op.Amount <= 0 or Op.Amount == math.huge then
		return nil
	end

	local Received = (Data._Received or {}) :: { [string]: any }
	if Dedupe.Has(Received, Dedupe.GRANT, Op.Rid) then
		return nil
	end

	local Kept: { [string]: any } = table.clone(Received)
	Kept[Dedupe.Key(Dedupe.GRANT, Op.Rid)] = Dedupe.Entry(Op.At, nil)

	local Next = table.clone(Data)
	Next[Field] = Data[Field] + Op.Amount
	Next._Received = Kept

	if not Dedupe.Has(Next._Received, Dedupe.GRANT, Op.Rid) then
		Fault.Broke(`booking {tostring(Op.Rid)} was paid in without being remembered, so it could pay again`)
		return nil
	end
	if Counted(Next._Booked) ~= Counted(Data._Booked) then
		Fault.Broke(`paying in booking {tostring(Op.Rid)} changed what the receiver has set aside`)
		return nil
	end
	return Next
end

local function Carried(Next: any, Data: { [any]: any }): any
	if type(Next) ~= "table" then
		return Next
	end

	local Plain = Next :: { [any]: any }
	if Plain._Booked == Data._Booked then
		return Next
	end

	if Plain._Booked ~= nil then
		Fault.Broke("your reducer wrote its own _Booked, so Ledger put the units set aside back")
	end

	local Merged = table.clone(Plain)
	Merged._Booked = Data._Booked
	return Merged
end

local function Wrap<S>(GameReducer: Reducer<S>): Reducer<S>
	local function Combined(State: S, Op: Op): S?
		local Data = State :: { [any]: any }
		local Kind = Op.Kind

		if Kind == BOOK then
			return Booking(Data, Op) :: any
		elseif Kind == TAKE then
			return Taking(Data, Op) :: any
		elseif Kind == FREE then
			return Freeing(Data, Op) :: any
		elseif Kind == GIVEN then
			return Giving(Data, Op) :: any
		end

		return Carried(GameReducer(State, Op), Data) :: any
	end

	return Combined
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

local function Give(Rid: string, Field: string, Amount: number): Op
	return { Id = `{GIVEN_ID}:{Rid}`, Kind = GIVEN, Rid = Rid, Field = Field, Amount = Amount, At = Clock.Now() } :: any
end

local function Delivered(State: any, Rid: string): boolean
	return Dedupe.Has((State :: any)._Received, Dedupe.GRANT, Rid)
end

local function Overdue(Data: { [any]: any }, Now: number): { string }
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

local function Take(Rid: string): Op
	return { Id = `{TAKE_ID}:{Rid}`, Kind = TAKE, Rid = Rid, At = Clock.Now() } :: any
end

local function Free(Rid: string): Op
	return { Id = `{FREE_ID}:{Rid}`, Kind = FREE, Rid = Rid, At = Clock.Now() } :: any
end

return table.freeze({
	Wrap = Wrap,
	Book = Book,
	Take = Take,
	Free = Free,
	Give = Give,
	Entry = Entry,
	Counted = Counted,
	Overdue = Overdue,
	Delivered = Delivered,
	BOOK_HORIZON = BOOK_HORIZON
})
