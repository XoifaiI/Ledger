--!strict
--!optimize 2

--[=[
	Cross: the rules between a store's settled options that no one option's rule can state: balance kinds and Balances
	against the default state and each other, windows against OrphanAge, totals against quantities, a quantity against
	the balance fields, and the default and balance bounds against Schema. Probe, for Studio only, warns when the
	reducer does not ignore an unknown kind.

	Return type: A plain table with Check and Probe.
	Example usage:
		Cross.Check(Settings, "Ledger.New")
--]=]

local Balance = require("./Balance")
local Balances = require("../../Tx/Legs/Balances")
local Check = require("../../Encoding/Check")
local Guards = require("../../Judging/Guards")
local Hot = require("../../Constants/Hot")
local Record = require("../../Constants/Record")
local Rules = require("./Rules")
local ShellSetup = require("../../Shell/Setup")
local Stepping = require("../../Shell/Stepping")
local Transaction = require("../../Constants/Transaction")

type Arithmetic = Balances.Arithmetic
type Declaration = Balances.Declaration
type Rule = Check.Rule
type Settings = ShellSetup.Settings

type Fields = { [string]: unknown }
type FieldSet = { [string]: Arithmetic }
type Kinds = { [string]: Declaration }
type NamedArithmetic = {
	Giver: string,
	Arithmetic: Arithmetic,
}

local AnyValue = Check.AnyValue
local BalancePath = Rules.BalancePath
local OpPath = Rules.OpPath
local QuantityPath = Rules.QuantityPath
local WindowPath = Rules.WindowPath

local DefaultArithmetic = Balances.DefaultArithmetic
local FreeField = Hot.FreeField
local OpenMode = Hot.Mode.Open

local WindowSigmas = Transaction.WindowSigmasBelowOrphanAge

local OpsKey = "Ops"
local ListGiver = "Balances"
local DefaultKey = "Default"
local MinKey = "Min"
local MaxKey = "Max"
local NegationKey = "Subtract(Zero, a)"
local NegationWanted = "an amount that Encode turns into a string"
local ListedCounted = "counting the fields Balances lists"
local ProceedsFreeField = `a balance field other than "{FreeField}", which is the free units of a part`
local ProceedsUndeclared = "a balance field that Balances lists or a balance kind in Ops declares"
local ProceedsRepeated = "a balance field that Proceeds does not name earlier"
local SharedName = "a name that no quantity in Quantities uses"

local function SameArithmeticWanted(First: NamedArithmetic, Field: string): string
	return `the arithmetic that {First.Giver} gives the field "{Field}"`
end

local function BelowOrphanAgeWanted(Limit: number): string
	return `below OrphanAge less {WindowSigmas} * Sigma, which is {Limit}`
end

local function SerialCountWanted(Count: number): string
	return `the count of Serials, {Count}`
end

local function ProbeWarning(Store: string, Problem: string): string
	return `Ledger: store {Store}: {Problem}`
end

local function SameArithmeticAs(First: NamedArithmetic, Field: string): Rule
	local Wanted = SameArithmeticWanted(First, Field)
	return function(Value: unknown): string?
		if Value == First.Arithmetic then
			return nil
		end
		return Wanted
	end
end

local function SortedOpKinds(Kinds: Kinds): { string }
	local Names: { string } = {}
	for OpKind in Kinds do
		table.insert(Names, OpKind)
	end
	table.sort(Names)
	return Names
end

local function GiverOf(OpKind: string): string
	return `the op kind "{OpKind}"`
end

local function OneArithmetic(Settings: Settings, Kinds: Kinds, Where: string): ()
	local Firsts: { [string]: NamedArithmetic } = {}
	for Field, Arithmetic in Settings.Balances do
		Firsts[Field] = { Giver = ListGiver, Arithmetic = Arithmetic }
	end
	for _, OpKind in SortedOpKinds(Kinds) do
		local Kind = Kinds[OpKind]
		local Arithmetic = Balances.ArithmeticOf(Kind)
		local First = Firsts[Kind.Field]
		if First == nil then
			Firsts[Kind.Field] = { Giver = GiverOf(OpKind), Arithmetic = Arithmetic }
			continue
		end
		Check.Table(
			{ Arithmetic = Arithmetic },
			{ Arithmetic = SameArithmeticAs(First, Kind.Field) },
			OpPath(Where, OpKind)
		)
	end
end

local function FieldsWanted(Most: number): string
	return `balance kinds on at most {Most} different fields, {ListedCounted}`
end

local function PartFieldWanted(Most: number): string
	return `balance kinds on at most {Most} different fields when Quantities declares a quantity, as its parts add `
		.. `the field "{FreeField}", {ListedCounted}`
end

local function AtMostFields(Most: number, Wanted: string): Rule
	return function(Count: unknown): string?
		if type(Count) == "number" and Count <= Most then
			return nil
		end
		return Wanted
	end
end

local function FieldCount(Settings: Settings, Fields: FieldSet, Where: string): ()
	local Count = 0
	for _ in Fields do
		Count += 1
	end
	local Rule = AtMostFields(Record.MoneyMax, FieldsWanted(Record.MoneyMax))
	if next(Settings.Quantities) ~= nil then
		Rule = AtMostFields(Record.MoneyMax - 1, PartFieldWanted(Record.MoneyMax - 1))
	end
	Check.Table({ [OpsKey] = Count }, { [OpsKey] = Rule }, Where)
end

local function DefaultFields(Fields: FieldSet, Default: Fields, Where: string): ()
	for Field, Arithmetic in Fields do
		Check.Table({ [Field] = Default[Field] }, { [Field] = Balance.IsAmountOf(Arithmetic) }, `{Where} Default`)
	end
end

local function EncodesNegation(Arithmetic: Arithmetic): Rule
	return function(Negated: unknown): string?
		if Negated ~= nil and type(Stepping.Run(Arithmetic.Encode, Negated)) == "string" then
			return nil
		end
		return NegationWanted
	end
end

local function SampleOf(Max: unknown?, Field: string, Arithmetic: Arithmetic, Default: Fields): unknown?
	if Max ~= nil then
		return Max
	end
	local Held = Default[Field]
	if Held ~= nil and Arithmetic.Compare(Held, Arithmetic.Zero) > 0 then
		return Held
	end
	return nil
end

local function CheckNegation(Arithmetic: Arithmetic, Amount: unknown, Path: string): ()
	local Negated = Stepping.Run(Arithmetic.Subtract, Arithmetic.Zero, Amount)
	Check.Table({ [NegationKey] = Negated }, { [NegationKey] = EncodesNegation(Arithmetic) }, Path)
end

local function CheckFieldNegations(
	Arithmetic: Arithmetic,
	Max: unknown?,
	Field: string,
	Default: Fields,
	Path: string
): ()
	if Arithmetic == DefaultArithmetic then
		return
	end
	CheckNegation(Arithmetic, Arithmetic.Zero, Path)
	local Sample = Stepping.Run(SampleOf, Max, Field, Arithmetic, Default)
	if Sample ~= nil then
		CheckNegation(Arithmetic, Sample, Path)
	end
end

local function SubtractsFromZero(Settings: Settings, Kinds: Kinds, Where: string): ()
	for OpKind, Kind in Kinds do
		local Arithmetic = Balances.ArithmeticOf(Kind)
		CheckFieldNegations(Arithmetic, Balances.MaxOf(Kind), Kind.Field, Settings.Default, OpPath(Where, OpKind))
	end
	for Field, Arithmetic in Settings.Balances do
		CheckFieldNegations(Arithmetic, Arithmetic.Max, Field, Settings.Default, BalancePath(Where, Field))
	end
end

local function BoundPath(OpKind: string, Bound: string): string
	return `{OpsKey}.{OpKind} {Bound}`
end

local function WithField(Default: Fields, Field: string, Amount: unknown): Fields
	local State = table.clone(Default)
	State[Field] = Amount
	return State
end

local function BoundsPassSchema(Settings: Settings, Kinds: Kinds, Where: string): ()
	for _, OpKind in SortedOpKinds(Kinds) do
		local Kind = Kinds[OpKind]
		if Kind.Min ~= nil then
			local AtMin = WithField(Settings.Default, Kind.Field, Kind.Min)
			Rules.CheckSchema(Settings.Schema, BoundPath(OpKind, MinKey), AtMin, Where)
		end
		if Kind.Max ~= nil then
			local AtMax = WithField(Settings.Default, Kind.Field, Kind.Max)
			Rules.CheckSchema(Settings.Schema, BoundPath(OpKind, MaxKey), AtMax, Where)
		end
	end
end

local function BelowOrphanAge(Settings: Settings): Rule
	local Wanted = BelowOrphanAgeWanted(Rules.WindowBoundOf(Settings))
	return function(Value: unknown): string?
		if type(Value) == "number" and Rules.IsBelowWindowBound(Value, Settings) then
			return nil
		end
		return Wanted
	end
end

local function Windows(Settings: Settings, Where: string): ()
	local Below = BelowOrphanAge(Settings)
	for OpKind, Window in Settings.Windows do
		Check.Table({ Timed = Window.Timed }, { Timed = Below }, WindowPath(Where, OpKind))
	end
end

local function UnusedByQuantities(Settings: Settings): Rule
	return function(Name: unknown): string?
		if type(Name) == "string" and Settings.Quantities[Name] ~= nil then
			return SharedName
		end
		return nil
	end
end

local function Totals(Settings: Settings, Where: string): ()
	local Unused = Check.Map(UnusedByQuantities(Settings), AnyValue)
	Check.Table({ Totals = Settings.Totals }, { Totals = Unused }, Where)
end

local function ProceedsField(Declared: FieldSet): Rule
	local Named: { [string]: boolean } = {}
	return function(Field: unknown): string?
		if Field == FreeField then
			return ProceedsFreeField
		end
		if type(Field) ~= "string" or Declared[Field] == nil then
			return ProceedsUndeclared
		end
		if Named[Field] then
			return ProceedsRepeated
		end
		Named[Field] = true
		return nil
	end
end

local function SerialCount(Count: number): Rule
	local Wanted = SerialCountWanted(Count)
	return function(Value: unknown): string?
		if Value == Count then
			return nil
		end
		return Wanted
	end
end

local FinalStockWanted = "a whole number of units: a Final quantity starts with its stock, so it must declare one"

local function FinalStockGiven(Value: unknown): string?
	return if Value == nil then FinalStockWanted else nil
end

local function Quantities(Settings: Settings, Declared: FieldSet, Where: string): ()
	for Name, Quantity in Settings.Quantities do
		local Path = QuantityPath(Where, Name)
		local Proceeds = Check.List(ProceedsField(Declared))
		Check.Table({ Proceeds = Quantity.Proceeds }, { Proceeds = Proceeds }, Path)
		if Quantity.Mode == OpenMode then
			Check.Table({ Stock = Quantity.Stock, Serials = Quantity.Serials }, {}, `{Path} in {OpenMode} mode`)
			continue
		end
		if Quantity.Serials ~= nil then
			Check.Table({ Stock = Quantity.Stock }, { Stock = SerialCount(Quantity.Serials.Count) }, Path)
		else
			Check.Table({ Stock = Quantity.Stock }, { Stock = FinalStockGiven }, Path)
		end
	end
end

local function CheckSettings(Settings: Settings, Where: string): ()
	local Kinds = ShellSetup.BalanceOpsOf(Settings)
	local Fields = ShellSetup.FieldArithmeticsOf(Settings)
	OneArithmetic(Settings, Kinds, Where)
	FieldCount(Settings, Fields, Where)
	DefaultFields(Fields, Settings.Default, Where)
	SubtractsFromZero(Settings, Kinds, Where)
	Windows(Settings, Where)
	Totals(Settings, Where)
	Quantities(Settings, Fields, Where)
	Rules.CheckSchema(Settings.Schema, DefaultKey, Settings.Default, Where)
	BoundsPassSchema(Settings, Kinds, Where)
end

local function Probe(Settings: Settings): ()
	local Reducer = Settings.Reducer
	if Reducer == nil then
		return
	end
	local Problem = Stepping.Run(function(): string?
		return Guards.ProbeUnknownKind(Reducer, Settings.Default, ShellSetup.FrozenInputs)
	end)
	if Problem ~= nil then
		warn(ProbeWarning(Settings.Name, Problem))
	end
end

return {
	Check = CheckSettings,
	Probe = Probe,
}
