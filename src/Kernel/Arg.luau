--!strict
--!optimize 2

--[=[
	Arg: The checks on arguments that the public methods share.

	These throw where the call was written. A wrong argument is a fault in the caller,
	and not a thing that went wrong, so it does not get a reason.

	A reducer cannot throw at a caller, so Positive answers the same question without one. Amount is
	the throwing half, for the argument a game hands in.

	Return type: A table with Positive, Amount, Field and Name.
	Example usage:
		local Arg = require("./Arg")
		Arg.Amount(Value, "Transfer")
--]=]

local function Positive(Value: any): boolean
	return type(Value) == "number" and Value > 0 and Value < math.huge
end

local function Amount(Value: any, What: string): number
	assert(Positive(Value), `{What} needs a positive finite Amount, got {tostring(Value)}`)
	return Value
end

local function Field(Initial: any, Named: any, What: string): string
	assert(type(Named) == "string" and #Named > 0 and type((Initial :: any)[Named]) == "number", `{What} needs Field to name a numeric field your Default declares, got '{tostring(Named)}'`)
	return Named
end

local function Name(Value: any, Limit: number, What: string, Optional: boolean): string?
	if Value == nil and Optional then
		return nil
	end

	assert(type(Value) == "string" and #Value > 0 and #Value <= Limit and utf8.len(Value) ~= nil, `{What} needs an Id, a stable name of 1 to {Limit} characters`)
	return Value
end

return table.freeze({
	Positive = Positive,
	Amount = Amount,
	Field = Field,
	Name = Name,
})
