--!strict
--!optimize 2

--[=[
	HoldOps: hold, confirm and release judged (hot keys sheet H5 P8 to P15, H10). A hold ends at the run's clock
	plus its duration. A confirm finds its hold, else takes, else is gone. A release writes even when no hold stands.

	Return type: A plain table with Hold, Confirm and Release, each a handler of Ops.
	Example usage:
		local Verdict = HoldOps.Hold(Setup, State, Record, Terms, Escrows, Clock)
--]=]

local Balances = require("../../Tx/Legs/Balances")
local Fates = require("../../Stored/Items/Fates")
local Holds = require("./Holds")
local HotShapes = require("../Shapes")
local JudgingShapes = require("../../Judging/Shapes")
local Part = require("../../Stored/Items/Part")
local Settle = require("./Settle")
local Shapes = require("../../Shapes")
local Work = require("../../Stored/Items/Work")

type Arithmetic = Balances.Arithmetic
type PlainPart = Part.PlainPart
type SerialPart = Part.SerialPart
type PartRecord = Part.PartRecord
type EscrowMark = Work.EscrowMark
type HoldTerms = HotShapes.HoldTerms
type ConfirmTerms = HotShapes.ConfirmTerms
type ReleaseTerms = HotShapes.ReleaseTerms
type Setup = Shapes.Setup
type Verdict = JudgingShapes.Verdict

type Fields = { [unknown]: unknown }
type Prices = { [string]: unknown }

local Direction = Balances.Direction
local PartReasons = Fates.PartReason
local RefusedFor = Settle.RefusedFor

local function HoldPlain(
	Arithmetics: { [string]: Arithmetic },
	State: Fields,
	Record: PlainPart,
	Terms: HoldTerms,
	End: number
): Verdict
	local Holding = Holds.WithPlainHold(Record, Terms.Id, Terms.Count, End)
	return Settle.MoveUnits(Arithmetics, State, Holding, Terms.Count, Direction.Debit)
end

local function HoldSerial(
	Arithmetics: { [string]: Arithmetic },
	State: Fields,
	Record: SerialPart,
	Terms: HoldTerms,
	End: number
): Verdict
	local Holding = Holds.WithSerialHold(Record, Terms.Id, Terms.Count, End)
	if Holding == nil then
		return RefusedFor(PartReasons.Free)
	end
	return Settle.MoveUnitsWith(Arithmetics, State, Holding.Record, Terms.Count, Direction.Debit, Holding.First)
end

local function Hold(
	Setup: Setup,
	State: Fields,
	Record: PartRecord,
	Terms: HoldTerms,
	Escrows: { EscrowMark },
	Clock: number
): Verdict
	local Refusal = Settle.TakeRefusal(State, Record, Escrows, Terms.Count)
	if Refusal ~= nil then
		return Refusal
	end
	if not Holds.HasHoldRoom(Record) then
		return RefusedFor(PartReasons.Holds)
	end
	local End = Clock + Terms.Duration
	if Record.IsSerial then
		return HoldSerial(Setup.Build.Balances, State, Record, Terms, End)
	end
	return HoldPlain(Setup.Build.Balances, State, Record, Terms, End)
end

local function ConfirmPlain(
	Arithmetics: { [string]: Arithmetic },
	State: Fields,
	Record: PlainPart,
	Place: number,
	Price: Prices
): Verdict
	local Standing = Record.Holds[Place]
	local Sold = Settle.AddSold(Holds.WithoutPlainHold(Record, Place), Standing.Count)
	return Settle.Settling(Arithmetics, Settle.Recorded(Settle.PayProceeds(State, Price, Arithmetics), Sold), Sold)
end

local function ConfirmSerial(
	Arithmetics: { [string]: Arithmetic },
	State: Fields,
	Record: SerialPart,
	Place: number,
	Price: Prices
): Verdict
	local Standing = Record.Holds[Place]
	local Sold = Settle.AddSold(Holds.WithoutSerialHold(Record, Place), Standing.Count)
	local Paid = Settle.Recorded(Settle.PayProceeds(State, Price, Arithmetics), Sold)
	return Settle.SettlingWith(Arithmetics, Paid, Sold, Standing.First)
end

local function ConfirmStanding(
	Arithmetics: { [string]: Arithmetic },
	State: Fields,
	Record: PartRecord,
	Place: number,
	Price: Prices
): Verdict
	if Record.IsSerial then
		return ConfirmSerial(Arithmetics, State, Record, Place, Price)
	end
	return ConfirmPlain(Arithmetics, State, Record, Place, Price)
end

local function Confirm(
	Setup: Setup,
	State: Fields,
	Record: PartRecord,
	Terms: ConfirmTerms,
	Escrows: { EscrowMark }
): Verdict
	local Arithmetics = Setup.Build.Balances
	local Place = Holds.FindHold(Record, Terms.Id)
	if Place ~= nil then
		return ConfirmStanding(Arithmetics, State, Record, Place, Terms.Price)
	end
	local Refusal = Settle.TakeRefusal(State, Record, Escrows, Terms.Count)
	if Refusal == nil then
		return Settle.Taken(Arithmetics, State, Record, Terms)
	end
	if Refusal.Kind == "RefusedFor" then
		return RefusedFor(PartReasons.Gone)
	end
	return Refusal
end

local function ReleasePlain(
	Arithmetics: { [string]: Arithmetic },
	State: Fields,
	Record: PlainPart,
	Place: number
): Verdict
	local Standing = Record.Holds[Place]
	local Kept = Holds.WithoutPlainHold(Record, Place)
	return Settle.MoveUnits(Arithmetics, State, Kept, Standing.Count, Direction.Credit)
end

local function ReleaseSerial(
	Arithmetics: { [string]: Arithmetic },
	State: Fields,
	Record: SerialPart,
	Place: number
): Verdict
	local Standing = Record.Holds[Place]
	local Kept = Holds.WithoutSerialHold(Record, Place)
	Holds.ReturnRun(Kept, Standing.First, Standing.Count)
	return Settle.MoveUnits(Arithmetics, State, Kept, Standing.Count, Direction.Credit)
end

local function Release(Setup: Setup, State: Fields, Record: PartRecord, Terms: ReleaseTerms): Verdict
	local Place = Holds.FindHold(Record, Terms.Id)
	if Place == nil then
		return { Kind = "Took", State = State }
	end
	if Record.IsSerial then
		return ReleaseSerial(Setup.Build.Balances, State, Record, Place)
	end
	return ReleasePlain(Setup.Build.Balances, State, Record, Place)
end

return {
	Hold = Hold,
	Confirm = Confirm,
	Release = Release,
}
