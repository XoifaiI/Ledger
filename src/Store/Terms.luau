--!strict
--!optimize 2

--[=[
	Terms: Logic. A transaction's legs as a game gives them, checked and made into Tx's legs.

	A leg is a field delta, with Field and Amount, or a game op, with Kind and Fields. Make throws at
	the game's call for a call that cannot run: fewer than two legs, two legs on one key, a delta on
	a field the store does not declare as money, an amount that is 0 or not a whole number below
	2^53, a game op a datastore cannot hold or one past OP_BYTES, a Once inside a leg, a hot leg that
	is not a leg, more legs than the LegLimit of any store a leg is in, or a mark or pinned record
	past Sizes.MARK_MAX. A call with no name is measured with the widest name Ledger draws. The
	decider is the hot leg, else the one game op leg, else the first leg that credits, else the last
	leg. A game name's print is 16 bits of the hash of every leg and which one decides. Depth counts
	the helpers between Make and the game's call, so each throw names the game's line.

	Return type: The Terms module, and the Given and Made types.
	Example usage:
		local Made = Terms.Make(Given, Name, Hot)
--]=]

local Asks = require("../Machine/Asks")
local Book = require("../Record/Book")
local Errors = require("../Core/Errors")
local Limits = require("../Core/Constants/Limits")
local Ops = require("./Ops")
local Requests = require("../Record/Requests")
local Sizes = require("../Core/Constants/Sizes")
local Tx = require("../Calls/Tx")
local Value = require("../Encode/Value")

local WorkForm = Book.WorkForm

export type Given = {
	read Ref: Book.Ref,
	read Place: Asks.Place,
	read MustExist: boolean,
	read Field: unknown,
	read Amount: unknown,
	read Kind: unknown,
	read Fields: unknown,
	read Slot: { string }?,
}

export type Made = {
	read Legs: { Tx.Leg },
	read Decider: number,
	read Print: number?,
}

local WIDEST_DRAWN = Book.Drawn(2 ^ 40, 2 ^ 40)

local OP_BYTES = 512

local Terms = {}

local function Delta(Leg: Given): (number?, number?)
	local Field, Amount = Leg.Field, Leg.Amount
	if type(Field) ~= "string" or type(Amount) ~= "number" then
		return nil, nil
	end
	return table.find(Leg.Place.Build.Money, Field), Amount
end

local function Whole(Amount: number): boolean
	return Amount ~= 0 and Amount % 1 == 0 and math.abs(Amount) < Limits.MONEY_LIMIT
end

local function Pick(Legs: { Tx.Leg }, Hot: number?): number
	if Hot then
		return Hot
	end
	local Games: { number } = {}
	local Credit: number? = nil
	for Index, Leg in Legs do
		local Change = Leg.Change
		if Change.Body ~= nil then
			table.insert(Games, Index)
		elseif Credit == nil and (Change.Amount or 0) > 0 then
			Credit = Index
		end
	end
	if #Games == 1 then
		return Games[1]
	end
	return Credit or #Legs
end

local function Widest(Name: string, Print: number?, Legs: { Tx.Leg }, Decider: number): number
	local Others: { Book.Ref } = {}
	for Index, Leg in Legs do
		if Index ~= Decider then
			table.insert(Others, Leg.Ref)
		end
	end
	local Pinned: Book.Pinned = { Form = WorkForm.Pinned, Stamp = 0, Attempt = Tx.ATTEMPTS, Print = Print, Legs = Others }
	local Mark: Book.Escrow = {
		Form = WorkForm.Escrow,
		Stamp = 0,
		Attempt = Tx.ATTEMPTS,
		Print = Print,
		Clean = true,
		Decider = Legs[Decider].Ref,
		Field = Limits.MONEY_MAX,
		Amount = -(Limits.MONEY_LIMIT - 1),
	}
	return math.max(Book.WorkWidth(Name, Pinned, 0), Book.WorkWidth(Name, Mark, 0))
end

local function GameOp(Leg: Given, Index: number, Depth: number): unknown
	if type(Leg.Kind) ~= "string" or (Leg.Fields ~= nil and type(Leg.Fields) ~= "table") then
		Errors.Misuse(`leg {Index} is neither a delta with Field and Amount nor a game op with Kind and Fields`, 3 + Depth)
	end
	local Fields = Leg.Fields :: { [string]: any }?
	if Fields and (Fields.Once ~= nil or Fields.OnceAt ~= nil) then
		Errors.Misuse(`leg {Index} carries Once, which names the whole transaction instead`, 3 + Depth)
	end
	local Body = Ops.Body(Leg.Kind :: string, Fields)
	local Bytes = Value.Check(Body)
	if Bytes == nil or Bytes > OP_BYTES then
		Errors.Misuse(`the op of leg {Index} is not one a datastore can hold in {OP_BYTES} bytes`, 3 + Depth)
	end
	return Body
end

local function Change(Leg: Given, Index: number, Depth: number): Requests.Leg
	local Field, Amount = Delta(Leg)
	if Field and Amount and Whole(Amount) then
		return { Field = Field, Amount = Amount }
	elseif Leg.Field ~= nil or Leg.Amount ~= nil then
		Errors.Misuse(`leg {Index} needs Field, a money field of its store, and Amount, a whole number of size 1 to 2^53`, 2 + Depth)
	end
	return { Body = GameOp(Leg, Index, Depth), Slot = Leg.Slot }
end

function Terms.Make(Given: { Given }, Name: string?, Hot: unknown, Depth: number?): Made
	local Extra = Depth or 0
	if #Given < Limits.LEGS_MIN then
		Errors.Misuse("a transaction needs at least two legs", 1 + Extra)
	elseif Hot ~= nil and not (type(Hot) == "number" and Given[Hot] ~= nil) then
		Errors.Misuse("Hot has to be the index of one of the legs", 1 + Extra)
	end
	local Seen: { [string]: true } = {}
	local Legs: { Tx.Leg } = {}
	local Printed: { { [string]: any } } = {}
	for Index, Leg in Given do
		local Place = Book.Address(Leg.Ref)
		if Seen[Place] then
			Errors.Misuse(`two legs are on the key {Place}`, 1 + Extra)
		elseif #Given > Leg.Place.Build.LegLimit then
			Errors.Misuse(`a transaction on {Leg.Ref.Store} has at most {Leg.Place.Build.LegLimit} legs`, 1 + Extra)
		end
		Seen[Place] = true
		local Made = Change(Leg, Index, Extra)
		Legs[Index] = { Ref = Leg.Ref, MustExist = Leg.MustExist, Erasable = Leg.Place.Build.Erasable, Change = Made }
		Printed[Index] = { Store = Leg.Ref.Store, Key = Leg.Ref.Key, Field = Made.Field, Amount = Made.Amount, Op = Made.Body, Slot = Made.Slot }
	end
	local Decider = Pick(Legs, if type(Hot) == "number" then Hot else nil)
	local Print = if Name then Ops.Print({ Legs = Printed, Decider = Decider }) else nil
	if Widest(Name or WIDEST_DRAWN, Print, Legs, Decider) > Sizes.MARK_MAX then
		Errors.Misuse(`the legs do not fit in {Sizes.MARK_MAX} bytes. use fewer legs or shorter keys`, 1 + Extra)
	end
	return { Legs = Legs, Decider = Decider, Print = Print }
end

return Terms
