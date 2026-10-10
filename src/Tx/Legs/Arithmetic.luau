--!strict
--!optimize 2

--[=[
	Arithmetic: the contract a balance field's values go through (internal/balances.md), and Ledger's default
	arithmetic, whole numbers below 2^53 in size written as decimal text.

	The default arithmetic throws on a value that is not a number. A stored balance field is checked with
	Balances.ReadBalance before it reaches one.

	Return type: A plain table with Default and RequireNumber, and the Arithmetic type.
	Example usage:
		local Sum = Arithmetic.Default.Add(Left, Right)
--]=]

local Record = require("../../Constants/Record")

export type Arithmetic = {
	read Zero: unknown,
	read Add: (Left: unknown, Right: unknown) -> unknown,
	read Subtract: (Left: unknown, Right: unknown) -> unknown,
	read Compare: (Left: unknown, Right: unknown) -> number,
	read IsValid: (Value: unknown) -> boolean,
	read Encode: (Value: unknown) -> string,
	read Decode: (Text: string) -> unknown?,
	read Max: unknown?,
}

local VarintLimit = Record.VarintLimit

local ModuleName = "Arithmetic"

local WholeNumberFormat = "%.0f"
local PositiveWholeText = "^[1-9]%d*$"
local ZeroText = "0"

local function NotANumber(Value: unknown): string
	return `{ModuleName}: the default arithmetic works on numbers, got a {type(Value)}. `
		.. "The caller must give it a number"
end

local function RequireNumber(Value: unknown): number
	if type(Value) ~= "number" then
		error(NotANumber(Value))
	end
	return Value
end

local function DefaultAdd(Left: unknown, Right: unknown): unknown
	return RequireNumber(Left) + RequireNumber(Right)
end

local function DefaultSubtract(Left: unknown, Right: unknown): unknown
	return RequireNumber(Left) - RequireNumber(Right)
end

local function DefaultCompare(Left: unknown, Right: unknown): number
	local LeftNumber = RequireNumber(Left)
	local RightNumber = RequireNumber(Right)
	if LeftNumber < RightNumber then
		return -1
	end
	if LeftNumber > RightNumber then
		return 1
	end
	return 0
end

local function DefaultIsValid(Value: unknown): boolean
	if type(Value) ~= "number" then
		return false
	end
	if Value % 1 ~= 0 then
		return false
	end
	return math.abs(Value) < VarintLimit
end

local function DefaultEncode(Value: unknown): string
	local Whole = RequireNumber(Value)
	if Whole == 0 then
		return ZeroText
	end
	return string.format(WholeNumberFormat, Whole)
end

local function DefaultDecode(Text: string): unknown?
	if Text == ZeroText then
		return 0
	end
	if not string.find(Text, PositiveWholeText) then
		return nil
	end
	local Value = tonumber(Text)
	if not Value or Value >= VarintLimit then
		return nil
	end
	return Value
end

local DefaultArithmetic: Arithmetic = table.freeze({
	Zero = 0,
	Add = DefaultAdd,
	Subtract = DefaultSubtract,
	Compare = DefaultCompare,
	IsValid = DefaultIsValid,
	Encode = DefaultEncode,
	Decode = DefaultDecode,
	Max = VarintLimit - 1,
})

return {
	Default = DefaultArithmetic,
	RequireNumber = RequireNumber,
}
