--!strict
--!optimize 2

--[=[
	Validate: The checks on arguments that the public methods share.

	These throw where the call was written. A wrong argument is a fault in the caller,
	and not a thing that went wrong, so it does not get a reason.

	A reducer cannot throw at a caller, so Positive answers the same question without one. Amount is
	the throwing half, for an argument a game hands in, and Number is the narrowing half, for a field
	read off an op.

	Name is for an Id a caller must give, and Maybe is the same check for one they may leave out, so
	neither hands back something a caller has to narrow before using it.

	Return type: A table with Positive, Number, Amount, Field, Name and Maybe.
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

return table.freeze({
	Positive = Positive,
	Number = Number,
	Amount = Amount,
	Field = Field,
	Name = Name,
	Maybe = Maybe,
})
