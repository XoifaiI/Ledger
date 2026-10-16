--!strict
--!optimize 2

--[=[
	Balances: the one owner of the rules about a balance (internal/balances.md "One owner").

	A value goes only through its arithmetic's own functions. A stored amount the field's arithmetic did not
	write, or a balance field it rejects (ReadBalance), reads as nil: Judge gives InvalidBalance, and an
	unreadable escrow amount or a settle on a rejected field Unreadable.

	Return type: A plain table of the functions, DefaultArithmetic, and the Direction and Verdict names, with
	the Arithmetic, Declaration, Pending and SignedValue types.
	Example usage:
		local Verdict = Balances.Judge(State, Marks, { Field = "Gold", Direction = "Debit" }, 50)
--]=]

local Amounts = require("../../Encoding/Amounts")
local Arithmetics = require("./Arithmetic")
local Record = require("../../Constants/Record")
local Work = require("../../Stored/Items/Work")

type EscrowMark = Work.EscrowMark
type SignedAmount = Amounts.SignedAmount
type UnsignedAmount = Amounts.UnsignedAmount

export type Arithmetic = Arithmetics.Arithmetic

local Direction = {
	Credit = "Credit" :: "Credit",
	Debit = "Debit" :: "Debit",
}

export type Direction = keyof<typeof(Direction)>

local Verdict = {
	Allowed = "Allowed" :: "Allowed",
	Refused = "Refused" :: "Refused",
	Unreadable = "Unreadable" :: "Unreadable",
	Invalid = "Invalid" :: "Invalid",
	InvalidBalance = "InvalidBalance" :: "InvalidBalance",
}

export type Verdict = keyof<typeof(Verdict)>

export type Declaration = {
	read Field: string,
	read Direction: Direction,
	read Min: unknown?,
	read Max: unknown?,
	read Arithmetic: Arithmetic?,
}

export type Pending = {
	Debits: unknown,
	Credits: unknown,
}

export type SignedValue = {
	Amount: unknown,
	IsNegative: boolean,
}

local WideLimb = Record.WideLimb

local DefaultArithmetic = Arithmetics.Default
local RequireNumber = Arithmetics.RequireNumber

local function ArithmeticOf(Declaration: Declaration): Arithmetic
	return Declaration.Arithmetic or DefaultArithmetic
end

local function MinOf(Declaration: Declaration): unknown
	if Declaration.Min ~= nil then
		return Declaration.Min
	end
	return ArithmeticOf(Declaration).Zero
end

local function MaxOf(Declaration: Declaration): unknown?
	if Declaration.Max ~= nil then
		return Declaration.Max
	end
	return ArithmeticOf(Declaration).Max
end

local function IsStorableText(Text: unknown): boolean
	if type(Text) ~= "string" or Text == "" then
		return false
	end
	return utf8.len(Text) ~= nil
end

local function IsStorableAmount(Stored: SignedAmount | UnsignedAmount): boolean
	if Stored.Kind == "Encoded" then
		return IsStorableText(Stored.Text)
	end
	return true
end

local function IsValidAmount(Arithmetic: Arithmetic, Amount: unknown): boolean
	if not Arithmetic.IsValid(Amount) then
		return false
	end
	return IsStorableText(Arithmetic.Encode(Amount))
end

local function WholeOfLimbs(High: number, Low: number): number?
	local Whole = High * WideLimb + Low
	if not DefaultArithmetic.IsValid(Whole) then
		return nil
	end
	return Whole
end

local function ToStored(Amount: unknown, Arithmetic: Arithmetic): UnsignedAmount
	if Arithmetic ~= DefaultArithmetic then
		return { Kind = "Encoded", Text = Arithmetic.Encode(Amount) }
	end
	local Whole = RequireNumber(Amount)
	return { Kind = "Default", High = Whole // WideLimb, Low = Whole % WideLimb }
end

local function FromStored(Stored: UnsignedAmount, Arithmetic: Arithmetic): unknown?
	if Stored.Kind == "Encoded" then
		if Arithmetic == DefaultArithmetic then
			return nil
		end
		return Arithmetic.Decode(Stored.Text)
	end
	if Arithmetic ~= DefaultArithmetic then
		return nil
	end
	return WholeOfLimbs(Stored.High, Stored.Low)
end

local function SignedFromStored(Stored: SignedAmount, Arithmetic: Arithmetic): SignedValue?
	if Stored.Kind == "Encoded" then
		if Arithmetic == DefaultArithmetic then
			return nil
		end
		local Value = Arithmetic.Decode(Stored.Text)
		if Value == nil then
			return nil
		end
		if Arithmetic.Compare(Value, Arithmetic.Zero) < 0 then
			return { Amount = Arithmetic.Subtract(Arithmetic.Zero, Value), IsNegative = true }
		end
		return { Amount = Value, IsNegative = false }
	end
	if Arithmetic ~= DefaultArithmetic then
		return nil
	end
	local Whole = WholeOfLimbs(Stored.High, Stored.Low)
	if Whole == nil then
		return nil
	end
	return { Amount = Whole, IsNegative = Stored.IsNegative }
end

local function SignedValueOf(Stored: SignedAmount, Arithmetic: Arithmetic): unknown?
	local Read = SignedFromStored(Stored, Arithmetic)
	if Read == nil then
		return nil
	end
	if Read.IsNegative then
		return Arithmetic.Subtract(Arithmetic.Zero, Read.Amount)
	end
	return Read.Amount
end

local function ToSignedStored(Amount: unknown, IsNegative: boolean, Arithmetic: Arithmetic): SignedAmount
	if Arithmetic ~= DefaultArithmetic then
		if IsNegative then
			local Negated = Arithmetic.Subtract(Arithmetic.Zero, Amount)
			return { Kind = "Encoded", Text = Arithmetic.Encode(Negated) }
		end
		return { Kind = "Encoded", Text = Arithmetic.Encode(Amount) }
	end
	local Whole = RequireNumber(Amount)
	return { Kind = "Default", IsNegative = IsNegative, High = Whole // WideLimb, Low = Whole % WideLimb }
end

local function SignedStoredOf(Value: unknown, Arithmetic: Arithmetic): SignedAmount
	if Arithmetic.Compare(Value, Arithmetic.Zero) < 0 then
		return ToSignedStored(Arithmetic.Subtract(Arithmetic.Zero, Value), true, Arithmetic)
	end
	return ToSignedStored(Value, false, Arithmetic)
end

local function BalanceOf(State: { [unknown]: unknown }, Field: string, Arithmetic: Arithmetic): unknown
	local Balance = State[Field]
	if Balance == nil then
		return Arithmetic.Zero
	end
	return Balance
end

local function ReadBalance(State: { [unknown]: unknown }, Field: string, Arithmetic: Arithmetic): unknown?
	local Balance = BalanceOf(State, Field, Arithmetic)
	if not IsValidAmount(Arithmetic, Balance) then
		return nil
	end
	return Balance
end

local function PendingOn(Marks: { EscrowMark }, Field: string, Arithmetic: Arithmetic): Pending | "Unreadable"
	local Sums = { Debits = Arithmetic.Zero, Credits = Arithmetic.Zero }
	for _, Mark in Marks do
		if Mark.Field ~= Field then
			continue
		end
		local Amount = FromStored(Mark.Amount, Arithmetic)
		if Amount == nil then
			return Verdict.Unreadable
		end
		if Mark.IsDebit then
			Sums.Debits = Arithmetic.Add(Sums.Debits, Amount)
		else
			Sums.Credits = Arithmetic.Add(Sums.Credits, Amount)
		end
	end
	return Sums
end

local function MayDebit(Balance: unknown, Pending: Pending, Amount: unknown, Declaration: Declaration): boolean
	local Arithmetic = ArithmeticOf(Declaration)
	local DebitsWithThis = Arithmetic.Add(Pending.Debits, Amount)
	local Lowest = Arithmetic.Add(MinOf(Declaration), DebitsWithThis)
	return Arithmetic.Compare(Balance, Lowest) >= 0
end

local function MayCredit(Balance: unknown, Pending: Pending, Amount: unknown, Declaration: Declaration): boolean
	local Max = MaxOf(Declaration)
	if Max == nil then
		return true
	end
	local Arithmetic = ArithmeticOf(Declaration)
	local CreditsWithThis = Arithmetic.Add(Pending.Credits, Amount)
	local Highest = Arithmetic.Add(Balance, CreditsWithThis)
	return Arithmetic.Compare(Highest, Max) <= 0
end

local function Judge(
	State: { [unknown]: unknown },
	Marks: { EscrowMark },
	Declaration: Declaration,
	Amount: unknown
): Verdict
	local Arithmetic = ArithmeticOf(Declaration)
	if not IsValidAmount(Arithmetic, Amount) then
		return Verdict.Invalid
	end
	local Balance = ReadBalance(State, Declaration.Field, Arithmetic)
	if Balance == nil then
		return Verdict.InvalidBalance
	end
	local Pending = PendingOn(Marks, Declaration.Field, Arithmetic)
	if Pending == Verdict.Unreadable then
		return Verdict.Unreadable
	end
	if Declaration.Direction == Direction.Debit then
		if not MayDebit(Balance, Pending, Amount, Declaration) then
			return Verdict.Refused
		end
		return Verdict.Allowed
	end
	if not MayCredit(Balance, Pending, Amount, Declaration) then
		return Verdict.Refused
	end
	return Verdict.Allowed
end

local function SettleValue(
	State: { [unknown]: unknown },
	Field: string,
	Amount: unknown,
	AmountDirection: Direction,
	Arithmetic: Arithmetic
): { [unknown]: unknown }
	local Settled = table.clone(State)
	if AmountDirection == Direction.Debit then
		Settled[Field] = Arithmetic.Subtract(BalanceOf(State, Field, Arithmetic), Amount)
		return Settled
	end
	Settled[Field] = Arithmetic.Add(BalanceOf(State, Field, Arithmetic), Amount)
	return Settled
end

local function SettleDebit(
	State: { [unknown]: unknown },
	Field: string,
	Stored: UnsignedAmount,
	Arithmetic: Arithmetic
): { [unknown]: unknown } | "Unreadable"
	local Amount = FromStored(Stored, Arithmetic)
	if Amount == nil or ReadBalance(State, Field, Arithmetic) == nil then
		return Verdict.Unreadable
	end
	return SettleValue(State, Field, Amount, Direction.Debit, Arithmetic)
end

local function SettleCredit(
	State: { [unknown]: unknown },
	Field: string,
	Stored: UnsignedAmount,
	Arithmetic: Arithmetic
): { [unknown]: unknown } | "Unreadable"
	local Amount = FromStored(Stored, Arithmetic)
	if Amount == nil or ReadBalance(State, Field, Arithmetic) == nil then
		return Verdict.Unreadable
	end
	return SettleValue(State, Field, Amount, Direction.Credit, Arithmetic)
end

local function AddAll(Addends: { unknown }, Arithmetic: Arithmetic): unknown
	local Sum = Arithmetic.Zero
	for _, Addend in Addends do
		Sum = Arithmetic.Add(Sum, Addend)
	end
	return Sum
end

local function IsValidBalance(Arithmetic: Arithmetic, Value: unknown): boolean
	return IsValidAmount(Arithmetic, Value)
end

local function HoldsInvalidBalance(State: { [unknown]: unknown }, Arithmetics: { [string]: Arithmetic }): boolean
	for Field, Arithmetic in Arithmetics do
		if not IsValidBalance(Arithmetic, State[Field]) then
			return true
		end
	end
	return false
end

local function IsCallAmount(Arithmetic: Arithmetic, Amount: unknown): boolean
	if not IsValidAmount(Arithmetic, Amount) then
		return false
	end
	return Arithmetic.Compare(Amount, Arithmetic.Zero) > 0
end

local function IsZero(Arithmetic: Arithmetic, Amount: unknown): boolean
	return Arithmetic.Compare(Amount, Arithmetic.Zero) == 0
end

return {
	Direction = Direction,
	Verdict = Verdict,
	DefaultArithmetic = DefaultArithmetic,
	ArithmeticOf = ArithmeticOf,
	MinOf = MinOf,
	MaxOf = MaxOf,
	ToStored = ToStored,
	FromStored = FromStored,
	SignedFromStored = SignedFromStored,
	SignedValueOf = SignedValueOf,
	ToSignedStored = ToSignedStored,
	SignedStoredOf = SignedStoredOf,
	IsStorableAmount = IsStorableAmount,
	ReadBalance = ReadBalance,
	PendingOn = PendingOn,
	Judge = Judge,
	SettleValue = SettleValue,
	SettleDebit = SettleDebit,
	SettleCredit = SettleCredit,
	AddAll = AddAll,
	IsValidBalance = IsValidBalance,
	HoldsInvalidBalance = HoldsInvalidBalance,
	IsCallAmount = IsCallAmount,
	IsZero = IsZero,
}
