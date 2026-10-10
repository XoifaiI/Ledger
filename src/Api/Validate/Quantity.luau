--!strict
--!optimize 2

--[=[
	Quantity: totals' and quantities' arguments (extras E2 step 1, hot keys H1 to H8, A11). Store:Total takes a
	declared total; a quantity's name throws, naming Quantity:Total, which totals its parts (PartsOf). A Bump's amount
	is bounded by ShardMax. A Take's name is a game name with its time; the core throws on a drawn one. A price leaves
	as a frozen copy (C7).

	Return type: A plain table with TotalOf, StoreTotalOf, PartsOf, TotalMaxAge, BumpAmount, QuantityOf, OpenAllowed,
	Count, Duration, Price, TakeName, TakeOptions, PartPlaceOf and PartFingerprintOf.
	Example usage:
		local Total = Quantity.TotalOf(Settings, "Visits", "Store:Bump")
		local Price, Name, Legs = Quantity.TakeOptions(Settings, Declaration, 1, { Price = 50 }, "Quantity:Take")
--]=]

local Args = require("./Args")
local Balance = require("./Balance")
local Check = require("../../Encoding/Check")
local ExtrasShapes = require("../../Extras/Shapes")
local Guards = require("../../Judging/Guards")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../../Hot/Shapes")
local KeyLegs = require("./KeyLegs")
local Leg = require("./Leg")
local Legs = require("./Legs")
local PartBuild = require("../../Hot/Part/Build")
local Record = require("../../Constants/Record")
local Rules = require("./Rules")
local Runner = require("../../Shell/Runner")
local Shard = require("../../Extras/Totals/Shard")
local ShellSetup = require("../../Shell/Setup")
local StoredValue = require("../../Stored/Value")

type CheckedLeg = Leg.CheckedLeg
type CheckedLegs = Legs.CheckedLegs
type Fields = StoredValue.Fields
type PartPlace = PartBuild.PartPlace
type QuantityDeclaration = HotShapes.QuantityDeclaration
type Rule = Check.Rule
type Settings = ShellSetup.Settings
type TakeName = HotShapes.TakeName
type TakeTerms = HotShapes.TakeTerms
type TotalDeclaration = ExtrasShapes.TotalDeclaration

type Prices = { [string]: unknown }

type TakeGiven = {
	Price: unknown,
	Id: unknown,
	IdAt: unknown,
	Legs: unknown,
}

local AnyValue = Check.AnyValue
local OrDefault = Rules.OrDefault
local Validated = Rules.Validated

local KeyKinds = Record.KeyKind

local TotalMaxAgeDefault = 0
local CountMost = Record.VarintLimit - 1
local PriceKey = "Price"

local CheckAccepted = "Quantity: a Check rule accepted a value of another type. The rule must reject it"
local ProceedsNotDeclared = "Quantity: a quantity's proceeds field is a balance field its store declares. "
	.. "Ledger.New checks it first"
local TotalWanted = "a total the store declares in Totals"
local QuantityWanted = "a quantity the store declares in Quantities"
local NoProceedsWanted = "nil, since the quantity declares no proceeds field"

local CountRule = Check.Whole(1, CountMost)
local StorablePrice = Rules.StorableAs(PriceKey)

local TakeRules: { [string]: Rule } = {
	Price = AnyValue,
	Id = AnyValue,
	IdAt = AnyValue,
	Legs = AnyValue,
}

local function ClosedQuantityOpened(Where: string, Store: string, Quantity: string): string
	return `{Where}: the quantity {Quantity} of the store {Store} is declared Closed; a closed quantity stays closed, `
		.. "and a restock is a new quantity"
end

local function QuantityTotalAsked(Where: string, Name: string): string
	return `{Where}: Name names the quantity {Name}, whose counts Store:Quantity("{Name}"):Total() answers; Name `
		.. "must be a total the store declares in Totals"
end

local function BumpAmountWanted(Most: number): string
	return `a whole number from -{Most} to {Most} other than 0`
end

local function PriceWanted(Proceeds: { string }): string
	local Listed = table.concat(Proceeds, ", ")
	if #Proceeds == 1 then
		return `a number, or a table of amounts by proceeds field ({Listed})`
	end
	return `a table of amounts by proceeds field ({Listed})`
end

local function PriceWhere(Where: string): string
	return `{Where} {PriceKey}`
end

local function DeclaredTotal(Settings: Settings): Rule
	return function(Value: unknown): string?
		if type(Value) == "string" and Settings.Totals[Value] ~= nil then
			return nil
		end
		return TotalWanted
	end
end

local function DeclaredQuantity(Settings: Settings): Rule
	return function(Value: unknown): string?
		if type(Value) == "string" and Settings.Quantities[Value] ~= nil then
			return nil
		end
		return QuantityWanted
	end
end

local function BumpSize(Most: number): Rule
	local Wanted = BumpAmountWanted(Most)
	return function(Value: unknown): string?
		if type(Value) ~= "number" or Value % 1 ~= 0 then
			return Wanted
		end
		local Size = math.abs(Value)
		if Size < 1 or Size > Most then
			return Wanted
		end
		return nil
	end
end

local function PriceForm(Proceeds: { string }): Rule
	if #Proceeds == 0 then
		return Rules.LeftOut(NoProceedsWanted)
	end
	local Wanted = PriceWanted(Proceeds)
	local ByField = Rules.Plain(Check.Map(Check.OneOf(table.unpack(Proceeds)), AnyValue))
	return function(Value: unknown): string?
		if type(Value) == "number" and #Proceeds == 1 then
			return nil
		end
		if type(Value) ~= "table" then
			return Wanted
		end
		return ByField(Value)
	end
end

local function PartsOf(Quantity: QuantityDeclaration): TotalDeclaration
	local Parts: TotalDeclaration = { Name = Quantity.Name, KeyCount = Quantity.Parts, Keys = KeyKinds.Part }
	return table.freeze(Parts)
end

local function CheckAmount(Settings: Settings, Field: string, Amount: unknown, Where: string): ()
	local Arithmetic = ShellSetup.FieldArithmeticsOf(Settings)[Field]
	assert(Arithmetic ~= nil, ProceedsNotDeclared)
	Check.Table({ [Field] = Amount }, { [Field] = Balance.IsCallAmountOf(Arithmetic) }, Where)
end

local function TotalOf(Settings: Settings, Name: unknown, Where: string): TotalDeclaration
	Check.Table({ Total = Name }, { Total = DeclaredTotal(Settings) }, Where)
	assert(type(Name) == "string", CheckAccepted)
	return Settings.Totals[Name]
end

local function StoreTotalOf(Settings: Settings, Name: unknown, Where: string): TotalDeclaration
	if type(Name) == "string" and Settings.Quantities[Name] ~= nil then
		error(QuantityTotalAsked(Where, Name), 0)
	end
	Check.Table({ Name = Name }, { Name = DeclaredTotal(Settings) }, Where)
	assert(type(Name) == "string", CheckAccepted)
	return Settings.Totals[Name]
end

local function TotalMaxAge(MaxAge: unknown, Where: string): number
	if MaxAge == nil then
		return TotalMaxAgeDefault
	end
	return Args.MaxAge(MaxAge, Where)
end

local function BumpAmount(Total: TotalDeclaration, Amount: unknown, Where: string): number
	local Most = Shard.ShardMax(Total.KeyCount)
	Check.Table({ Amount = Amount }, { Amount = BumpSize(Most) }, Where)
	assert(type(Amount) == "number", CheckAccepted)
	return Amount
end

local function QuantityOf(Settings: Settings, Name: unknown, Where: string): QuantityDeclaration
	Check.Table({ Name = Name }, { Name = DeclaredQuantity(Settings) }, Where)
	assert(type(Name) == "string", CheckAccepted)
	return Settings.Quantities[Name]
end

local function OpenAllowed(Settings: Settings, Quantity: QuantityDeclaration, Where: string): ()
	if Settings.ClosedQuantities[Quantity.Name] == true then
		error(ClosedQuantityOpened(Where, Settings.Name, Quantity.Name), 0)
	end
end

local function Count(Value: unknown, Where: string): number
	Check.Table({ Count = Value }, { Count = CountRule }, Where)
	assert(type(Value) == "number", CheckAccepted)
	return Value
end

local function Duration(Settings: Settings, Value: unknown, Where: string): number
	Check.Table({ Duration = Value }, { Duration = Check.Whole(1, Settings.HoldMax) }, Where)
	assert(type(Value) == "number", CheckAccepted)
	return Value
end

local function Price(Settings: Settings, Quantity: QuantityDeclaration, Value: unknown, Where: string): Prices
	if Value == nil then
		return {}
	end
	local Proceeds = Quantity.Proceeds
	Check.Table({ Price = Value }, { Price = PriceForm(Proceeds) }, Where)
	if type(Value) == "number" then
		local Field = Proceeds[1]
		CheckAmount(Settings, Field, Value, PriceWhere(Where))
		return { [Field] = Value }
	end
	Check.Table({ Price = Value }, { Price = StorablePrice }, Where)
	assert(type(Value) == "table", CheckAccepted)
	local Paid = Guards.DeepCopy(Value :: Fields)
	Guards.DeepFreeze(Paid)
	for Field, Amount in Paid do
		assert(type(Field) == "string", CheckAccepted)
		CheckAmount(Settings, Field, Amount, PriceWhere(Where))
	end
	return Paid :: Prices
end

local function TakeNameOf(Name: unknown, At: unknown, Where: string): TakeName?
	local Given = Args.GameName(Args.InOptions, Name, At, Where)
	if Given == nil then
		return nil
	end
	assert(Given.Kind == "Game", CheckAccepted)
	local Stamp = Given.Stamp
	assert(Stamp ~= nil, CheckAccepted)
	return { Kind = "Game", Text = Given.Text, Stamp = Stamp }
end

local function PartPlaceOf(Settings: Settings, Quantity: QuantityDeclaration): PartPlace
	return { Store = Settings.Name, Scope = ShellSetup.StoreScope, Quantity = Quantity }
end

local function PartFingerprintOf(Settings: Settings, Quantity: QuantityDeclaration): number
	return PartBuild.FingerprintOf(Runner.OpenedSetup(Settings.Name).Encoding, Quantity)
end

local function WidestTakeLeg(Settings: Settings, Quantity: QuantityDeclaration, Units: number, Paid: Prices): CheckedLeg
	local Terms: TakeTerms = { Fingerprint = PartFingerprintOf(Settings, Quantity), Count = Units, Price = Paid }
	local Widest = PartBuild.PartLeg(PartPlaceOf(Settings, Quantity), Quantity.Parts - 1, Hot.PartOpKind.Take, Terms)
	return KeyLegs.CheckedOf(Widest, Settings)
end

local function TakeOptions(
	Settings: Settings,
	Quantity: QuantityDeclaration,
	Units: number,
	Options: unknown,
	Where: string
): (Prices, TakeName?, CheckedLegs)
	local Given = Validated(OrDefault(Options, Rules.NoFields), TakeRules, Where) :: TakeGiven
	local Paid = Price(Settings, Quantity, Given.Price, Where)
	local Name = TakeNameOf(Given.Id, Given.IdAt, Where)
	if Given.Legs == nil then
		return Paid, Name, Legs.NoLegs
	end
	local Part = WidestTakeLeg(Settings, Quantity, Units, Paid)
	return Paid, Name, Legs.TakeLegs(Part, Given.Legs, Quantity, Name, Where)
end

return {
	TotalOf = TotalOf,
	StoreTotalOf = StoreTotalOf,
	PartsOf = PartsOf,
	TotalMaxAge = TotalMaxAge,
	BumpAmount = BumpAmount,
	QuantityOf = QuantityOf,
	OpenAllowed = OpenAllowed,
	Count = Count,
	Duration = Duration,
	Price = Price,
	TakeName = TakeNameOf,
	TakeOptions = TakeOptions,
	PartPlaceOf = PartPlaceOf,
	PartFingerprintOf = PartFingerprintOf,
}
