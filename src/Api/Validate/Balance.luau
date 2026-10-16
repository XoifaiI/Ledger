--!strict
--!optimize 2

--[=[
	Balance: a balance kind (a Credit or Debit name under a Balances field) and its arithmetic as Check rules, run
	marked as Stepping. Settle freezes the bounds and keeps one copy per game arithmetic, shared with the Balances
	list; a kind with none takes its listed field's.

	Return type: A plain table with Settle, ListedArithmetic, IsAmountOf and IsCallAmountOf, and the Copies and Listed
	types.
	Example usage:
		local Kind = { Field = "Gold", Direction = "Debit", Min = 0 }
		local Settled = Balance.Settle(Kind, {}, { Gold = Arithmetic }, "Ledger.New Balances kind SpendGold")
--]=]

local Balances = require("../../Tx/Legs/Balances")
local Check = require("../../Encoding/Check")
local Rules = require("./Rules")
local Stepping = require("../../Shell/Stepping")

type Arithmetic = Balances.Arithmetic
type Declaration = Balances.Declaration
type Direction = Balances.Direction
type Rule = Check.Rule

type KindGiven = {
	Field: string,
	Direction: Direction,
	Min: unknown,
	Max: unknown,
	Arithmetic: unknown,
}

export type Copies = { [unknown]: Arithmetic }
export type Listed = { [string]: Arithmetic }

local AnyValue = Check.AnyValue
local FrozenAmount = Rules.FrozenAmount
local Validated = Rules.Validated

local Directions = Balances.Direction

local NonEmptyText = Check.TextAtLeast(1)

local ZeroKey = "Zero"
local MinKey = "Min"
local MaxKey = "Max"

local CheckAccepted = "Balance: a Check rule accepted a value of another type. The rule must reject it"
local ValidAmountWanted = "a valid amount of its arithmetic"
local NotAboveMaxWanted = "an amount of its arithmetic that is not above Max"
local CallAmountWanted = "a positive amount, valid under its arithmetic"

local OptionRules: { [string]: Rule } = {
	Min = AnyValue,
	Max = AnyValue,
	Arithmetic = AnyValue,
}

local KindRules = table.clone(OptionRules)
KindRules.Field = NonEmptyText
KindRules.Direction = Check.OneOf(Directions.Credit, Directions.Debit)

local ArithmeticRules: { [string]: Rule } = {
	Zero = AnyValue,
	Add = Check.Function,
	Subtract = Check.Function,
	Compare = Check.Function,
	IsValid = Check.Function,
	Encode = Check.Function,
	Decode = Check.Function,
	Max = AnyValue,
}

local function ArithmeticPath(Where: string): string
	return `{Where} Arithmetic`
end

local function IsAmountOf(Arithmetic: Arithmetic): Rule
	return function(Value: unknown): string?
		if Stepping.Run(Balances.IsValidBalance, Arithmetic, Value) then
			return nil
		end
		return ValidAmountWanted
	end
end

local function IsCallAmountOf(Arithmetic: Arithmetic): Rule
	return function(Value: unknown): string?
		if Stepping.Run(Balances.IsCallAmount, Arithmetic, Value) then
			return nil
		end
		return CallAmountWanted
	end
end

local function NotAbove(Arithmetic: Arithmetic, Max: unknown): Rule
	return function(Value: unknown): string?
		if Stepping.Run(Arithmetic.Compare, Value, Max) <= 0 then
			return nil
		end
		return NotAboveMaxWanted
	end
end

local function ArithmeticCopy(Value: unknown, Where: string): Arithmetic
	local Path = ArithmeticPath(Where)
	local Given = Validated(Value, ArithmeticRules, Path)
	Given.Zero = FrozenAmount(Given.Zero, ZeroKey, Path)
	Given.Max = FrozenAmount(Given.Max, MaxKey, Path)
	local Arithmetic = Given :: Arithmetic
	local IsAmount = IsAmountOf(Arithmetic)
	Check.Table(
		{ Zero = Arithmetic.Zero, Max = Arithmetic.Max },
		{ Zero = IsAmount, Max = Check.Optional(IsAmount) },
		Path
	)
	return table.freeze(Arithmetic)
end

local function SharedCopy(Value: unknown, Copies: Copies, Where: string): Arithmetic?
	if Value == nil then
		return nil
	end
	if Value == Balances.DefaultArithmetic then
		return Balances.DefaultArithmetic
	end
	local Made = Copies[Value]
	if Made == nil then
		Made = ArithmeticCopy(Value, Where)
		Copies[Value] = Made
	end
	return Made
end

local function CheckBounds(Kind: Declaration, Where: string): ()
	local Arithmetic = Balances.ArithmeticOf(Kind)
	local IsAmount = IsAmountOf(Arithmetic)
	Check.Table(
		{ Min = Kind.Min, Max = Kind.Max },
		{ Min = Check.Optional(IsAmount), Max = Check.Optional(IsAmount) },
		Where
	)
	local Max = Balances.MaxOf(Kind)
	if Max ~= nil then
		Check.Table({ Min = Balances.MinOf(Kind) }, { Min = NotAbove(Arithmetic, Max) }, Where)
	end
end

local function ListedArithmetic(Value: unknown, Copies: Copies, Where: string): Arithmetic
	if Value == true then
		return Balances.DefaultArithmetic
	end
	local Made = SharedCopy(Value, Copies, Where)
	assert(Made ~= nil, CheckAccepted)
	return Made
end

local function KindBeforeBounds(Value: unknown, Copies: Copies, Declared: Listed, Where: string): Declaration
	local Given = Validated(Value, KindRules, Where) :: KindGiven
	local Own = SharedCopy(Given.Arithmetic, Copies, Where)
	return {
		Field = Given.Field,
		Direction = Given.Direction,
		Min = FrozenAmount(Given.Min, MinKey, Where),
		Max = FrozenAmount(Given.Max, MaxKey, Where),
		Arithmetic = if Own == nil then Declared[Given.Field] else Own,
	}
end

local function Settle(Value: unknown, Copies: Copies, Declared: Listed, Where: string): Declaration
	local Kind = KindBeforeBounds(Value, Copies, Declared, Where)
	CheckBounds(Kind, Where)
	return table.freeze(Kind)
end

return {
	Settle = Settle,
	ListedArithmetic = ListedArithmetic,
	IsAmountOf = IsAmountOf,
	IsCallAmountOf = IsCallAmountOf,
}
