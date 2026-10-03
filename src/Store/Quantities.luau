--!strict
--!optimize 2

--[=[
	Quantities: Object. The split quantities a store declares, and each call on one.

	Each quantity's parts are a place of their own, a store whose build is the part build. A quantity
	keeps a view of its parts, what each last showed free and whether it was shut. A walk picks parts
	by the view, every refusal goes into it, and a Stock read fills it. Find, Units, Indexed, Priced,
	Ticketed and Legs throw at the game's call. A take's own legs are checked with the part as the
	last leg, since the part decides, and only then is the part left off for Walk to add each try. A
	credit that finds its one part sold out or short answers Refused, since nothing was credited. A
	confirm that finds its part sold out answers Short. A move with no part goes to this server's
	home part. Stock's sold units are exact once sold out, and the rest is advice.

	Return type: The Quantities module, and the Quantity, Splits, Stock, Ticket and Taken types.
	Example usage:
		local Reply, Taken = Quantities.Take(Held, Body, Legs, nil, nil, nil, nil)
--]=]

local Answer = require("../Core/Answer")
local Book = require("../Record/Book")
local Clock = require("../Machine/Clock")
local DataStore = require("../Adapters/DataStore")
local Errors = require("../Core/Errors")
local Limits = require("../Core/Constants/Limits")
local Ops = require("./Ops")
local Parts = require("../Record/Parts")
local Queue = require("../Record/Queue")
local Runner = require("../Machine/Runner")
local Runtime = require("./Runtime")
local Shards = require("../Record/Shards")
local Split = require("../Calls/Split")
local Terms = require("./Terms")
local Totals = require("./Totals")
local Transactions = require("./Transactions")
local Tx = require("../Calls/Tx")
local Types = require("../Record/Types")
local Walk = require("../Calls/Walk")

type Answer = Answer.Answer
type Reply = Queue.Reply

export type Quantity = {
	read Declared: Parts.Declared,
	read View: { [number]: Walk.View },
	read Total: Shards.Held,
}

export type Splits = { [string]: Quantity }

export type Stock = {
	read Free: number,
	read Held: number,
	read Sold: number,
	read SoldOut: boolean,
}

export type Ticket = {
	read Quantity: string,
	read Id: string,
	read Part: number,
	read Count: number,
	read Ends: number,
	read Serials: { number }?,
}

export type Taken = Walk.Result

local SLOT = Parts.SLOT

local Shared = Runtime.Shared

local function Walking(Held: Quantity, Body: Parts.Op, Legs: { Tx.Leg }, Only: number?, Name: string?, Stamp: number?, Print: number?): Taken
	local Declared = Held.Declared
	local Home = Shards.Home(Declared.Name, Shared:First(), Declared.Parts)
	local Server = Shared:Server()
	local At = Stamp or Clock.Now()
	local Names: { string } = {}
	if Name == nil then
		for _ = 1, Parts.PROBES do
			table.insert(Names, Shared:Draw())
		end
	end
	local Asked: Walk.Asked = {
		Declared = Declared,
		Body = Body,
		Legs = Legs,
		Server = Server,
		Home = Home,
		Only = Only,
		Name = Name,
		Stamp = At,
		Print = Print,
		Names = Names,
		View = Held.View,
	}
	local Found = Runner.Run(Walk.Machine, Walk.Context(Asked), Shared.Places):Wait()
	return Found or { Reply = Answer.Unresolved }
end

local function Splitting(Held: Quantity, Of: typeof(Split.Open), Suffix: string): (Reply, Split.Closed?)
	local Declared = Held.Declared
	local Context = Split.Context(Declared, `{Declared.Name}:{Suffix}`, Clock.Now(), Shared:Server())
	local Found = Runner.Run(Of, Context, Shared.Places):Wait()
	if type(Found) == "table" then
		local Closed = Found :: Split.Closed
		return Closed.Reply, Closed
	end
	return if Found == nil then Answer.Unresolved else Found, nil
end

local Quantities = {}

function Quantities.Declare(Splits: Splits, Store: string, Data: DataStore.Store, Made: Types.Build, Declared: { [string]: Parts.Declared })
	for Name, Each in Declared do
		Splits[Name] = { Declared = Each, View = {}, Total = Shards.New(Store, Name, Each.Parts, Parts.KIND) }
		Shared.Places[Each.Place] = { Store = Data, Build = Parts.Build(Made, Each) }
	end
end

function Quantities.Find(Splits: Splits, Store: string, Name: string): Quantity
	local Found = Splits[Name]
	if Found == nil then
		Errors.Misuse(`{Store} declares no split quantity named {Name}`, 1)
	end
	return Found :: Quantity
end

function Quantities.Units(Count: unknown)
	if not (type(Count) == "number" and Count % 1 == 0 and Count >= 1 and Count < Limits.MONEY_LIMIT) then
		Errors.Misuse("Count has to be a whole number of 1 or more", 1)
	end
end

function Quantities.Indexed(Held: Quantity, Part: unknown, What: string)
	local Count = Held.Declared.Parts
	if not (type(Part) == "number" and Part % 1 == 0 and Part >= 0 and Part < Count) then
		Errors.Misuse(`{What} has to be a part of {Held.Declared.Name}, from 0 to {Count - 1}`, 1)
	end
end

function Quantities.Priced(Held: Quantity, Price: unknown): { [string]: number }?
	if Price == nil then
		return nil
	elseif type(Price) ~= "table" then
		Errors.Misuse("Price has to be a table of proceeds fields and amounts", 1)
	end
	local Made: { [string]: number } = {}
	for Field, Amount in Price :: { [any]: any } do
		if not table.find(Held.Declared.Proceeds, Field) then
			Errors.Misuse(`{Field} is not a proceeds field of {Held.Declared.Name}`, 1)
		elseif not (type(Amount) == "number" and Amount % 1 == 0 and Amount >= 1 and Amount < Limits.MONEY_LIMIT) then
			Errors.Misuse(`the price of {Field} has to be a whole number of 1 or more`, 1)
		end
		Made[Field] = Amount
	end
	return Made
end

function Quantities.Ticketed(Splits: Splits, Held: Ticket): Quantity
	local Found = if type(Held) == "table" and type(Held.Quantity) == "string" then Splits[Held.Quantity] else nil
	if Found == nil or type(Held.Id) ~= "string" or type(Held.Part) ~= "number" or type(Held.Count) ~= "number" then
		Errors.Misuse("a ticket has to be one Hold gave back", 1)
	end
	return Found :: Quantity
end

function Quantities.Legs(Held: Quantity, Given: { read [number]: Transactions.Asked }?, Body: Parts.Op, Name: string?): ({ Tx.Leg }, number?)
	local Declared = Held.Declared
	if Given == nil or Given[1] == nil then
		return {}, if Name then Ops.Print({ Quantity = Declared.Name, Op = Body }) else nil
	end
	local Gathered = Transactions.Gather(Given, 1, Declared.First ~= nil)
	local Part: Book.Ref = { Store = Declared.Place, Key = Parts.Key(Declared.Name, Declared.Parts, 0) }
	table.insert(Gathered, { Ref = Part, Place = Shared.Places[Declared.Place], MustExist = true, Kind = Body.Kind, Fields = Body })
	local Made = Terms.Make(Gathered, Name, #Gathered, 1)
	local Legs = table.clone(Made.Legs)
	table.remove(Legs)
	return Legs, Made.Print
end

function Quantities.PartLeg(Held: Quantity, Index: number, Field: string, Amount: number): Terms.Given
	local Declared = Held.Declared
	local Part: Book.Ref = { Store = Declared.Place, Key = Parts.Key(Declared.Name, Declared.Parts, Index) }
	return { Ref = Part, Place = Shared.Places[Declared.Place], MustExist = true, Field = Field, Amount = Amount }
end

function Quantities.Toward(Given: Terms.Given, Amount: number): Terms.Given
	return { Ref = Given.Ref, Place = Given.Place, MustExist = Given.MustExist, Field = Given.Field, Amount = Amount }
end

function Quantities.Open(Held: Quantity): Reply
	return (Splitting(Held, Split.Open, "open"))
end

function Quantities.Close(Held: Quantity): (Reply, Split.Closed?)
	return Splitting(Held, Split.Close, "close")
end

function Quantities.Take(Held: Quantity, Body: Parts.Op, Legs: { Tx.Leg }, Only: number?, Name: string?, Stamp: number?, Print: number?): (Reply, Taken)
	local Found = Walking(Held, Body, Legs, Only, Name, Stamp, Print)
	return Found.Reply, Found
end

function Quantities.Hold(Held: Quantity, Count: number, Seconds: number): (Reply, Ticket?)
	local Declared = Held.Declared
	local Id = Shared:Mint()
	local Now = Clock.Now()
	local Body = Parts.HoldOp(Declared.Print, Id, Count, Now + Seconds)
	local Found = Walking(Held, Body, {}, nil, nil, Now, nil)
	local Part = Found.Part
	if Found.Reply ~= true or Part == nil then
		return Found.Reply, nil
	end
	local Serials: { number }? = nil
	local Kept = Found.State :: Parts.Part?
	for _, Each in if type(Kept) == "table" then Kept.Holds else {} do
		Serials = if Each.Id == Id then Each.Serials else Serials
	end
	return true, { Quantity = Declared.Name, Id = Id, Part = Part, Count = Count, Ends = Now + Seconds + Limits.EPOCH, Serials = Serials }
end

function Quantities.Confirm(Held: Quantity, Body: Parts.Op, Legs: { Tx.Leg }, Part: number): (Reply, Taken)
	local Found = Walking(Held, Body, Legs, Part)
	return if Found.Reply == Answer.SoldOut then Answer.Short else Found.Reply, Found
end

function Quantities.Release(Held: Quantity, Body: Parts.Op, Part: number): Reply
	return Walking(Held, Body, {}, Part).Reply
end

function Quantities.Credit(Held: Quantity, Body: Parts.Op, Part: number?): Reply
	local Declared = Held.Declared
	local Only = Part or Shards.Home(Declared.Name, Shared:First(), Declared.Parts)
	local Found = Walking(Held, Body, {}, Only)
	return if Found.Reply == Answer.SoldOut or Found.Reply == Answer.Short then Answer.Refused else Found.Reply
end

function Quantities.Move(Made: Terms.Made, Held: Quantity, Index: number?, Slot: number): Reply
	local Legs = Made.Legs
	if Index == nil then
		local Declared = Held.Declared
		local Home = Shards.Home(Declared.Name, Shared:First(), Declared.Parts)
		local Old = Legs[Slot]
		Legs = table.clone(Legs)
		Legs[Slot] = { Ref = { Store = Declared.Place, Key = Parts.Key(Declared.Name, Declared.Parts, Home) }, MustExist = Old.MustExist, Erasable = Old.Erasable, Change = Old.Change }
	end
	return (Transactions.Run({ Legs = Legs, Decider = Made.Decider, Print = Made.Print }, nil, nil))
end

function Quantities.Stock(Held: Quantity, MaxAge: number): Stock | Answer
	local Found = Totals.Sums(Held.Total, MaxAge)
	if type(Found) ~= "table" then
		return Found
	end
	local Now = Clock.Now()
	for Index, Pair in Held.Total.Pairs do
		local Values = Pair.Values
		local Free = Values[SLOT.Free]
		Held.View[Index] = { Free = Free, Shut = Values[SLOT.Shut] == 1, Refused = if Free == 0 then 1 else nil, At = Now }
	end
	return { Free = Found[SLOT.Free], Held = Found[SLOT.Held], Sold = Found[SLOT.Sold], SoldOut = Found[SLOT.Shut] == Held.Declared.Parts }
end

function Quantities.Gather(Held: Quantity, Count: number, Given: { Terms.Given }, Room: number): (Reply, Taken)
	Quantities.Stock(Held, Parts.VIEW_AGE)
	local Free: { [number]: number } = {}
	for Index, Seen in Held.View do
		Free[Index] = Seen.Free
	end
	local Plan = Parts.Plan(Free, Held.Declared.Parts, Count, Room)
	if Plan == nil then
		return Answer.Short, { Reply = Answer.Short, Reason = "Free" }
	end
	local Legs: { Terms.Given } = {}
	for _, Step in Plan do
		table.insert(Legs, Quantities.PartLeg(Held, Step.Index, "Free", -Step.Count))
	end
	local Parted = #Legs
	table.move(Given, 1, #Given, Parted + 1, Legs)
	local Reply, Context = Transactions.Run(Terms.Make(Legs, nil, nil), nil, nil)
	local Refuser = if Context then Context.Refuser else nil
	if Reply ~= true and Refuser and Refuser <= Parted then
		return Answer.Short, { Reply = Answer.Short, Reason = "Free" }
	end
	return Reply, { Reply = Reply }
end

return Quantities
