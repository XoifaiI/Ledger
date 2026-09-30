--!strict
--!optimize 2

--[=[

	Terms: Logic. A transaction's legs as a game gives them, checked and made into Tx's legs.

	Spec: transaction 3 and 3.1.

	A leg is a field delta, with Field and Amount, or a game op, with Kind and Fields. Make throws at
	the game's call for a call that cannot run: fewer than two legs, two legs on one key, a delta on
	a field the store does not declare as money, an amount that is 0 or not a whole number below
	2^53, a game op a datastore cannot hold or past Limits.OP_BYTES, a Once inside a leg, a hot leg
	that is not a leg, and a mark or pinned record past Sizes.MARK_MAX. A call with no name is measured
	with the widest name Ledger draws. The decider is the hot leg,
	else the one game op leg, else the first leg that credits, else the last leg. A game name's print
	is 16 bits of the hash of every leg and which one decides.

	Return type: A table with Make. The types are Given and Made.
	Example usage:
		local Made = Terms.Make(Given, Name, Hot)
--]=]

local Book = require("../Record/Book")
local Canon = require("../Encode/Canon")
local Errors = require("../Core/Errors")
local Hash = require("../Encode/Hash")
local Limits = require("../Core/Constants/Limits")
local Ops = require("./Ops")
local Sizes = require("../Core/Constants/Sizes")
local Asks = require("../Machine/Asks")
local Tx = require("../Calls/Tx")
local Value = require("../Encode/Value")

export type Given = {
	read Ref: Book.Ref,
	read Place: Asks.Place,
	read MustExist: boolean,
	read Field: unknown,
	read Amount: unknown,
	read Kind: unknown,
	read Fields: unknown,
}

local WIDEST_DRAWN = Book.Drawn(2 ^ 40, 2 ^ 40)

export type Made = {
	read Legs: { Tx.Leg },
	read Decider: number,
	read Print: number?,
}

local MONEY_LIMIT = 2 ^ 53

local Terms = {}

local function Where(Ref: Book.Ref): string
	return `{Ref.Store}/{Ref.Key}`
end

local function Delta(Leg: Given): (number?, number?)
	local Field, Amount = Leg.Field, Leg.Amount
	if type(Field) ~= "string" or type(Amount) ~= "number" then
		return nil, nil
	end
	return table.find(Leg.Place.Build.Money, Field), Amount
end

local function Whole(Amount: number): boolean
	return Amount ~= 0 and Amount % 1 == 0 and math.abs(Amount) < MONEY_LIMIT
end

local function Pick(Legs: { Tx.Leg }, Hot: number?): number
	if Hot then
		return Hot
	end
	--TODO: Meh
	local Game: number? = nil
	local Games, Credit = 0, nil
	for Index, Leg in Legs do
		local Change = Leg.Change
		if Change.Body ~= nil then
			Games += 1
			Game = Game or Index
		elseif Credit == nil and (Change.Amount or 0) > 0 then
			Credit = Index
		end
	end
	return if Games == 1 and Game then Game else Credit or #Legs
end

local function Widest(Name: string, Print: number?, Legs: { Tx.Leg }, Decider: number): number
	local Others: { Book.Ref } = {}
	for Index, Leg in Legs do
		if Index ~= Decider then
			table.insert(Others, Leg.Ref)
		end
	end
	local Pinned: Book.Pinned = { Form = "Pinned", Stamp = 0, Attempt = Limits.ATTEMPTS, Print = Print, Legs = Others }
	local Mark: Book.Escrow = {
		Form = "Escrow",
		Stamp = 0,
		Attempt = Limits.ATTEMPTS,
		Print = Print,
		Clean = true,
		Decider = Legs[Decider].Ref,
		Field = Limits.MONEY_MAX,
		Amount = -(MONEY_LIMIT - 1),
	}
	return math.max(Book.WorkWidth(Name, Pinned, 0), Book.WorkWidth(Name, Mark, 0))
end

--TODO: Space out
function Terms.Make(Given: { Given }, Name: string?, Hot: unknown): Made
	if #Given < 2 then
		Errors.Misuse("a transaction needs at least two legs", 1)
	elseif Hot ~= nil and not (type(Hot) == "number" and Given[Hot] ~= nil) then
		Errors.Misuse("Hot has to be the index of one of the legs", 1)
	end
	local Chosen = if type(Hot) == "number" then Hot else nil
	local Seen: { [string]: true } = {}
	local Legs: { Tx.Leg } = {}
	local Printed: { { [string]: any } } = {}
	for Index, Leg in Given do
		local Place = Where(Leg.Ref)
		if Seen[Place] then
			Errors.Misuse(`two legs are on the key {Place}`, 1)
		end
		Seen[Place] = true
		local Field, Amount = Delta(Leg)
		local Change: { Field: number?, Amount: number?, Body: unknown? } = {}
		if Field and Amount and Whole(Amount) then
			Change.Field, Change.Amount = Field, Amount
		elseif Leg.Field ~= nil or Leg.Amount ~= nil then
			Errors.Misuse(`leg {Index} needs Field, a money field of its store, and Amount, a whole number of size 1 to 2^53`, 1)
		elseif type(Leg.Kind) ~= "string" or (Leg.Fields ~= nil and type(Leg.Fields) ~= "table") then
			Errors.Misuse(`leg {Index} is neither a delta with Field and Amount nor a game op with Kind and Fields`, 1)
		else
			local Fields = Leg.Fields :: { [string]: any }?
			if Fields and (Fields.Once ~= nil or Fields.OnceAt ~= nil) then
				Errors.Misuse(`leg {Index} carries Once, which names the whole transaction instead`, 1)
			end
			local Body = Ops.Body(Leg.Kind, Fields)
			local Bytes = Value.Check(Body)
			if Bytes == nil or Bytes > Limits.OP_BYTES then
				Errors.Misuse(`the op of leg {Index} is not one a datastore can hold in {Limits.OP_BYTES} bytes`, 1)
			end
			Change.Body = Body
		end
		Legs[Index] = { Ref = Leg.Ref, MustExist = Leg.MustExist, Change = Change }
		Printed[Index] = { s = Leg.Ref.Store, k = Leg.Ref.Key, f = Change.Field, a = Change.Amount, o = Change.Body }
	end
	local Decider = Pick(Legs, Chosen)
	local Print = if Name then bit32.band(Hash(Canon({ Legs = Printed, Decider = Decider })), 0xFFFF) else nil
	if Widest(Name or WIDEST_DRAWN, Print, Legs, Decider) > Sizes.MARK_MAX then
		Errors.Misuse(`the legs do not fit in {Sizes.MARK_MAX} bytes. use fewer legs or shorter keys`, 1)
	end
	return { Legs = Legs, Decider = Decider, Print = Print }
end

return Terms
