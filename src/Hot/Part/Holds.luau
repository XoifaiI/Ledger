--!strict
--!optimize 2

--[=[
	Holds: the holds, serial runs and seal of a part record (hot keys sheet H4 steps 2 and 5, H10). ReturnRun and
	DrawSerials change the caller's own copy: its lists are replaced, an entry is never edited.
	ExpireHolds, SealIfDone and the With and Without functions return a new table. The clock must be usable.

	Return type: A plain table of functions.
	Example usage:
		local First = Holds.DrawSerials(Record, 3) --> 100
--]=]

local Amounts = require("../../Encoding/Amounts")
local Balances = require("../../Tx/Legs/Balances")
local Hot = require("../../Constants/Hot")
local JudgingRun = require("../../Judging/Run")
local Lookup = require("../../Stored/Lookup")
local Names = require("../../Encoding/Names")
local Part = require("../../Stored/Items/Part")
local Shapes = require("../../Shapes")
local Value = require("../../Stored/Value")
local Work = require("../../Stored/Items/Work")

type Name = Names.Name
type Arithmetic = Balances.Arithmetic
type SerialRun = Part.SerialRun
type PartRecord = Part.PartRecord
type PlainPart = Part.PlainPart
type SerialPart = Part.SerialPart
type Kept = Value.Kept
type Fields = Value.Fields
type Limits = Shapes.Limits
type Run = JudgingRun.Run
type Mark = Work.Mark

local RecordOf = Part.RecordOf
local FreeOf = Part.FreeOf
local IsSameName = Lookup.IsSameName
local IsZero = Balances.IsZero
local IsZeroAmount = Amounts.IsZeroAmount
local EscrowMarksOf = Work.EscrowMarksOf

local FreeField = Hot.FreeField
local PartRecordKey = Hot.PartRecordKey
local HoldRoom = Hot.HoldRoom

local NoUnits = 0

local ModuleName = "Holds"
local TooFewSerials =
	`{ModuleName}: the part has fewer serials than asked for. The caller must give a part whose u is within its serials`

local function IsHigherRun(Left: SerialRun, Right: SerialRun): boolean
	return Left.First > Right.First
end

local function IsExpired(End: number, Clock: number, Limits: Limits): boolean
	return End + Limits.HoldSlack < Clock or End - Clock > Limits.Ceiling + Limits.HoldSlack
end

local function SerialsLeft(Record: SerialPart): number
	local Left = Record.SerialEnd - Record.SerialNext
	for _, Run in Record.Returned do
		Left += Run.Count
	end
	return Left
end

local function IsDrained(State: Fields, Record: PartRecord): boolean
	if State[FreeField] ~= NoUnits or #Record.Holds > 0 then
		return false
	end
	return not Record.IsSerial or #Record.Returned == 0
end

local function AreProceedsZero(State: Fields, Record: PartRecord, Arithmetics: { [string]: Arithmetic }): boolean
	for Field, Arithmetic in Arithmetics do
		local Amount = State[Field]
		if Field ~= FreeField and Amount ~= nil and not IsZero(Arithmetic, Amount) then
			return false
		end
	end
	for _, Entry in Record.Carried do
		if not IsZeroAmount(Entry.Amount) then
			return false
		end
	end
	return true
end

local function ReturnRun(Record: SerialPart, First: number, Count: number)
	local Start = First
	local Total = Count
	local Returned: { SerialRun } = {}
	for _, Run in Record.Returned do
		if Run.First + Run.Count == First then
			Start = Run.First
			Total += Run.Count
		elseif Run.First == First + Count then
			Total += Run.Count
		else
			table.insert(Returned, Run)
		end
	end
	table.insert(Returned, { First = Start, Count = Total })
	table.sort(Returned, IsHigherRun)
	Record.Returned = Returned
end

local function DrawSerials(Record: SerialPart, Count: number): number
	if SerialsLeft(Record) < Count then
		error(TooFewSerials)
	end
	local Returned = table.clone(Record.Returned)
	local Lowest = Returned[#Returned]
	local First = if Lowest == nil then Record.SerialNext else Lowest.First
	local Needed = Count
	while Needed > 0 and #Returned > 0 do
		local Place = #Returned
		local Run = Returned[Place]
		local Drawn = math.min(Needed, Run.Count)
		if Drawn == Run.Count then
			table.remove(Returned, Place)
		else
			Returned[Place] = { First = Run.First + Drawn, Count = Run.Count - Drawn }
		end
		Needed -= Drawn
	end
	Record.Returned = Returned
	Record.SerialNext += Needed
	return First
end

local function TakeRun(Record: SerialPart, Count: number): SerialRun?
	if Record.SerialNext + Count <= Record.SerialEnd then
		local Fresh: SerialRun = { First = Record.SerialNext, Count = Count }
		Record.SerialNext += Count
		return Fresh
	end
	for Place = #Record.Returned, 1, -1 do
		local Run = Record.Returned[Place]
		if Run.Count < Count then
			continue
		end
		local Returned = table.clone(Record.Returned)
		if Run.Count == Count then
			table.remove(Returned, Place)
		else
			Returned[Place] = { First = Run.First + Count, Count = Run.Count - Count }
		end
		Record.Returned = Returned
		return { First = Run.First, Count = Count }
	end
	return nil
end

local function WithoutAt<Item>(Items: { Item }, Place: number): { Item }
	local Kept = table.clone(Items)
	table.remove(Kept, Place)
	return Kept
end

local function WithoutPlainHold(Record: PlainPart, Place: number): PlainPart
	local Kept = table.clone(Record)
	Kept.Holds = WithoutAt(Record.Holds, Place)
	return Kept
end

local function WithoutSerialHold(Record: SerialPart, Place: number): SerialPart
	local Kept = table.clone(Record)
	Kept.Holds = WithoutAt(Record.Holds, Place)
	return Kept
end

local function WithPlainHold(Record: PlainPart, Id: Name, Count: number, End: number): PlainPart
	local Holding = table.clone(Record)
	Holding.Holds = table.clone(Record.Holds)
	table.insert(Holding.Holds, { Id = Id, Count = Count, End = End })
	return Holding
end

local function WithSerialHold(
	Record: SerialPart,
	Id: Name,
	Count: number,
	End: number
): { Record: SerialPart, First: number }?
	local Holding = table.clone(Record)
	local Run = TakeRun(Holding, Count)
	if Run == nil then
		return nil
	end
	Holding.Holds = table.clone(Record.Holds)
	table.insert(Holding.Holds, { Id = Id, Count = Count, End = End, First = Run.First })
	return { Record = Holding, First = Run.First }
end

local function ExpirePlain(Record: PlainPart, Clock: number, Limits: Limits): (PlainPart, number)
	local Expired = table.clone(Record)
	Expired.Holds = {}
	local Units = 0
	for _, Standing in Record.Holds do
		if IsExpired(Standing.End, Clock, Limits) then
			Units += Standing.Count
		else
			table.insert(Expired.Holds, Standing)
		end
	end
	return Expired, Units
end

local function ExpireSerial(Record: SerialPart, Clock: number, Limits: Limits): (SerialPart, number)
	local Expired = table.clone(Record)
	Expired.Holds = {}
	Expired.Returned = table.clone(Record.Returned)
	local Units = 0
	for _, Standing in Record.Holds do
		if IsExpired(Standing.End, Clock, Limits) then
			Units += Standing.Count
			ReturnRun(Expired, Standing.First, Standing.Count)
		else
			table.insert(Expired.Holds, Standing)
		end
	end
	return Expired, Units
end

local function ExpireHolds(Key: Kept, Clock: number, Limits: Limits)
	local Record = RecordOf(Key.State)
	local Expired: PartRecord
	local Units: number
	if Record.IsSerial then
		Expired, Units = ExpireSerial(Record, Clock, Limits)
	else
		Expired, Units = ExpirePlain(Record, Clock, Limits)
	end
	if #Expired.Holds == #Record.Holds then
		return
	end
	local State = table.clone(Key.State)
	State[FreeField] = FreeOf(Key.State) + Units
	State[PartRecordKey] = Expired
	Key.State = State
end

local function HeldUnits(Record: PartRecord): number
	local Units = 0
	for _, Standing in Record.Holds do
		Units += Standing.Count
	end
	return Units
end

local function FindHold(Record: PartRecord, Id: Name): number?
	for Place, Standing in Record.Holds do
		if IsSameName(Standing.Id, Id) then
			return Place
		end
	end
	return nil
end

local function HasHoldRoom(Record: PartRecord): boolean
	if Record.IsSerial then
		return #Record.Holds + #Record.Returned < HoldRoom
	end
	return #Record.Holds < HoldRoom
end

local function IsEmpty(
	State: Fields,
	Record: PartRecord,
	Items: { Mark },
	Arithmetics: { [string]: Arithmetic }
): boolean
	if not IsDrained(State, Record) or #Items > 0 then
		return false
	end
	return AreProceedsZero(State, Record, Arithmetics)
end

local function SealIfDone(Run: Run)
	local Record = RecordOf(Run.State)
	if not Record.IsFinal or Record.IsSealed then
		return
	end
	if not IsDrained(Run.State, Record) or #EscrowMarksOf(Run.Book.Work) > 0 then
		return
	end
	local Sealed = table.clone(Record)
	Sealed.IsSealed = true
	local State = table.clone(Run.State)
	State[PartRecordKey] = Sealed
	Run.State = State
end

return {
	ExpireHolds = ExpireHolds,
	ReturnRun = ReturnRun,
	DrawSerials = DrawSerials,
	HeldUnits = HeldUnits,
	SerialsLeft = SerialsLeft,
	FindHold = FindHold,
	HasHoldRoom = HasHoldRoom,
	IsEmpty = IsEmpty,
	SealIfDone = SealIfDone,
	WithoutPlainHold = WithoutPlainHold,
	WithoutSerialHold = WithoutSerialHold,
	WithPlainHold = WithPlainHold,
	WithSerialHold = WithSerialHold,
}
