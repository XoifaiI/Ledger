--!strict
--!optimize 2

--[=[
	Settle: what the part's rules share when an op settles (hot keys sheet H4 step 3, H5). The refusal a take and a
	hold both meet, the price paid into the proceeds, units moved between u and a record, and the limit a settled
	state must keep: past it, or with no t_open, the state is Unreadable, never encoded.

	Return type: A plain table of functions.
	Example usage:
		local Refusal = Settle.TakeRefusal(State, Record, Escrows, 3)
--]=]

local Balances = require("../../Tx/Legs/Balances")
local Fates = require("../../Stored/Items/Fates")
local Holds = require("./Holds")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../Shapes")
local JudgingShapes = require("../../Judging/Shapes")
local Part = require("../../Stored/Items/Part")
local VarintLimit = require("../../Constants/Record").VarintLimit
local Verdicts = require("../../Judging/Verdicts")
local Wide = require("../../Encoding/Wide")
local Work = require("../../Stored/Items/Work")

type Arithmetic = Balances.Arithmetic
type Declaration = Balances.Declaration
type AmountDirection = Balances.Direction
type PartReason = Fates.PartReason
type PartRecord = Part.PartRecord
type EscrowMark = Work.EscrowMark
type TakeTerms = HotShapes.TakeTerms
type Verdict = JudgingShapes.Verdict

type Fields = { [unknown]: unknown }

local FreeOf = Part.FreeOf
local DefaultArithmetic = Balances.DefaultArithmetic
local Direction = Balances.Direction
local FreeField = Hot.FreeField
local PartRecordKey = Hot.PartRecordKey
local IsPlainSigned = Wide.IsPlainSigned

local PartReasons = Fates.PartReason

local FreeDebit: Declaration = table.freeze({ Field = FreeField, Direction = Direction.Debit })

local ModuleName = "Settle"
local PriceNotProceeds =
	`{ModuleName}: a price names only the proceeds fields the build declares, never u. The API checks it`

local function RefusedFor(Reason: PartReason): Verdict
	return { Kind = "RefusedFor", Reason = Reason }
end

local function ClosedOrSealed(Record: PartRecord): PartReason?
	if Record.IsClosed then
		return PartReasons.Closed
	end
	if Record.IsSealed then
		return PartReasons.Sealed
	end
	return nil
end

local function ShortReason(State: Fields, Record: PartRecord, Count: number): PartReason
	if FreeOf(State) + Holds.HeldUnits(Record) >= Count then
		return PartReasons.Held
	end
	return PartReasons.Free
end

local function TakeRefusal(State: Fields, Record: PartRecord, Escrows: { EscrowMark }, Count: number): Verdict?
	local Barred = ClosedOrSealed(Record)
	if Barred ~= nil then
		return RefusedFor(Barred)
	end
	local Allowance = Balances.Judge(State, Escrows, FreeDebit, Count)
	if Allowance == Balances.Verdict.Unreadable then
		return Verdicts.Unreadable
	end
	if Allowance == Balances.Verdict.Invalid or Allowance == Balances.Verdict.InvalidBalance then
		return Verdicts.Invalid
	end
	if Allowance == Balances.Verdict.Refused then
		return RefusedFor(ShortReason(State, Record, Count))
	end
	return nil
end

local function PayProceeds(State: Fields, Price: { [string]: unknown }, Arithmetics: { [string]: Arithmetic }): Fields
	local Paid = table.clone(State)
	for Field, Amount in Price do
		local Arithmetic = Arithmetics[Field]
		if Arithmetic == nil or Field == FreeField then
			error(PriceNotProceeds)
		end
		Paid = Balances.SettleValue(Paid, Field, Amount, Direction.Credit, Arithmetic)
	end
	return Paid
end

local function AddSold(Record: PartRecord, Count: number): PartRecord
	local Sold = table.clone(Record)
	Sold.Sold += Count
	return Sold
end

local function Recorded(Owned: Fields, Kept: PartRecord): Fields
	Owned[PartRecordKey] = Kept
	return Owned
end

local function IsWithinLimits(State: Fields, Record: PartRecord, Arithmetics: { [string]: Arithmetic }): boolean
	if Record.Sold >= VarintLimit or FreeOf(State) + Holds.HeldUnits(Record) >= VarintLimit then
		return false
	end
	if Record.IsSerial and FreeOf(State) > Holds.SerialsLeft(Record) then
		return false
	end
	local OpenedAt = Record.OpenedAt
	if OpenedAt == nil then
		return false
	end
	for _, Standing in Record.Holds do
		if math.abs(Standing.End) >= VarintLimit or not IsPlainSigned(Standing.End - OpenedAt) then
			return false
		end
	end
	for Field, Arithmetic in Arithmetics do
		local Balance = State[Field]
		if Balance ~= nil and not Balances.IsValidBalance(Arithmetic, Balance) then
			return false
		end
	end
	return true
end

local function Settling(Arithmetics: { [string]: Arithmetic }, State: Fields, Record: PartRecord): Verdict
	if not IsWithinLimits(State, Record, Arithmetics) then
		return Verdicts.Unreadable
	end
	return { Kind = "Took", State = State }
end

local function SettlingWith(
	Arithmetics: { [string]: Arithmetic },
	State: Fields,
	Record: PartRecord,
	FirstSerial: number
): Verdict
	if not IsWithinLimits(State, Record, Arithmetics) then
		return Verdicts.Unreadable
	end
	return { Kind = "TookWith", State = State, Value = FirstSerial }
end

local function UnitsMoved(State: Fields, Kept: PartRecord, Count: number, Moving: AmountDirection): Fields
	local Moved = Balances.SettleValue(State, FreeField, Count, Moving, DefaultArithmetic)
	return Recorded(Moved, Kept)
end

local function MoveUnits(
	Arithmetics: { [string]: Arithmetic },
	State: Fields,
	Kept: PartRecord,
	Count: number,
	Moving: AmountDirection
): Verdict
	return Settling(Arithmetics, UnitsMoved(State, Kept, Count, Moving), Kept)
end

local function MoveUnitsWith(
	Arithmetics: { [string]: Arithmetic },
	State: Fields,
	Kept: PartRecord,
	Count: number,
	Moving: AmountDirection,
	FirstSerial: number
): Verdict
	return SettlingWith(Arithmetics, UnitsMoved(State, Kept, Count, Moving), Kept, FirstSerial)
end

local function Taken(
	Arithmetics: { [string]: Arithmetic },
	State: Fields,
	Record: PartRecord,
	Terms: TakeTerms
): Verdict
	local Sold = AddSold(Record, Terms.Count)
	local Paid = PayProceeds(State, Terms.Price, Arithmetics)
	if Sold.IsSerial then
		local First = Holds.DrawSerials(Sold, Terms.Count)
		return MoveUnitsWith(Arithmetics, Paid, Sold, Terms.Count, Direction.Debit, First)
	end
	return MoveUnits(Arithmetics, Paid, Sold, Terms.Count, Direction.Debit)
end

return {
	RefusedFor = RefusedFor,
	TakeRefusal = TakeRefusal,
	PayProceeds = PayProceeds,
	AddSold = AddSold,
	Recorded = Recorded,
	Settling = Settling,
	SettlingWith = SettlingWith,
	MoveUnits = MoveUnits,
	MoveUnitsWith = MoveUnitsWith,
	Taken = Taken,
}
