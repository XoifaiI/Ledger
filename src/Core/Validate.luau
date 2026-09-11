--!strict
--!optimize 2

--[=[

	Validate: The argument checks the public methods share.

	Amount, Field and Name throw where the call was written. Positive and Number answer the same
	questions without throwing, for a reducer that cannot. Maybe is Name for an argument a caller may
	leave out.

	Op and Numbered narrow rather than check. Op says whether a value is shaped like one, which two
	public methods asked in the same five clauses each. Numbered reads a number off a state that may
	not be a table and may not have the field, which is the shape of every read of a stock or a
	balance out of a fold.

	Return type: A table with Positive, Number, Amount, Field, Name, Maybe, Op and Numbered.
	Example usage:
		local Validate = require("./Validate")
		Validate.Amount(Value, "Transfer")
--]=]

local function Positive(Value: any): boolean
	return type(Value) == "number" and Value > 0 and Value < math.huge
end

local function Number(Value: any): number?
	return if Positive(Value) then Value else nil
end

local function Amount(Value: any, What: string): number
	assert(Positive(Value), `{What} needs a positive finite Amount, got {tostring(Value)}`)
	return Value
end

local function Field(Initial: any, Named: any, What: string): string
	assert(type(Named) == "string" and #Named > 0 and type(Initial[Named]) == "number", `{What} needs Field to name a numeric field your Default declares, got '{tostring(Named)}'`)
	return Named
end

local function Name(Value: any, Limit: number, What: string): string
	assert(type(Value) == "string" and #Value > 0 and #Value <= Limit and utf8.len(Value) ~= nil, `{What} needs an Id, a stable name of 1 to {Limit} characters`)
	return Value
end

local function Maybe(Value: any, Limit: number, What: string): string?
	return if Value == nil then nil else Name(Value, Limit, What)
end

local function Op(Value: any): boolean
	if type(Value) ~= "table" then
		return false
	end

	local Id, Kind = Value.Id, Value.Kind
	return type(Id) == "string" and #Id > 0 and type(Kind) == "string" and #Kind > 0
end

local function Numbered(State: any, Named: any): number?
	if type(State) ~= "table" or type(Named) ~= "string" then
		return nil
	end

	local Found = State[Named]
	return if type(Found) == "number" then Found else nil
end

return table.freeze({
	Positive = Positive,
	Number = Number,
	Amount = Amount,
	Field = Field,
	Name = Name,
	Maybe = Maybe,
	Op = Op,
	Numbered = Numbered,
})
