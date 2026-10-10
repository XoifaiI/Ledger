--!strict
--!optimize 2

--[=[
	Setup: Ledger.New's options as Check rules, settled into Shell/Setup's Settings; balance kinds are Balance's.
	Each other table is read raw before kinds run the game's arithmetic; the default state is frozen.
	Balances names each balance field's credit and debit kinds, by name (the field's bounds) or as { Kind, Min?, Max? }
	(its own); every other kind is the reducer's and is never listed. A field keeps its arithmetic with no kind on it:
	never remove one. OnLoadFailed never replaces the kick.

	Return type: A plain table with Settle.
	Example usage:
		local Settings = Setup.Settle(Options, "Ledger.New")
--]=]

local Balance = require("./Balance")
local Balances = require("../../Tx/Legs/Balances")
local Check = require("../../Encoding/Check")
local Extras = require("../../Constants/Extras")
local ExtrasShapes = require("../../Extras/Shapes")
local Guards = require("../../Judging/Guards")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../../Hot/Shapes")
local Json = require("../../Encoding/Json")
local PublicTypes = require("../../Types")
local Record = require("../../Constants/Record")
local Rules = require("./Rules")
local Settable = require("../../Constants/Settable")
local ShellSetup = require("../../Shell/Setup")

type Declaration = Balances.Declaration
type KindWindows = ShellSetup.KindWindows
type LoadFailedHandler = ShellSetup.LoadFailedHandler
type Rule = Check.Rule
type Serials = HotShapes.Serials
type SettledMigration = ShellSetup.SettledMigration
type Settings = ShellSetup.Settings

type Named = { [string]: unknown }
type Tree = { [unknown]: unknown }
type Ops = ShellSetup.Ops
type Direction = Balances.Direction

type Settling = {
	Listed: Balance.Listed,
	Ops: Ops,
	Seen: { [string]: true },
	Copies: Balance.Copies,
}

type KindGiven = {
	Kind: string,
	Min: unknown,
	Max: unknown,
}

type KindItem = string | KindGiven

type FieldGiven = {
	Credit: (string | { KindItem })?,
	Debit: (string | { KindItem })?,
	Min: unknown,
	Max: unknown,
	Arithmetic: unknown,
}

type OptionsGiven = {
	Name: string,
	Keys: ShellSetup.KeysMode,
	Default: unknown,
	Reducer: Guards.Reducer<unknown, unknown, unknown>?,
	Schema: ShellSetup.ResultSchema<unknown>?,
	Balances: Named?,
	Migrations: { unknown }?,
	MustExist: boolean,
	Erasable: boolean,
	LegLimit: number?,
	OnLoadFailed: LoadFailedHandler?,
	Kick: boolean?,
	KickMessage: string?,
	SaveInterval: number?,
	IdleReadInterval: number?,
	HoldMax: number?,
	OrphanAge: number?,
	Windows: Named?,
	CutWindow: number?,
	Totals: Named?,
	Quantities: Named?,
	Mock: unknown?,
}

type MigrationGiven = PublicTypes.Migration
type WindowGiven = index<PublicTypes.Windows, string>
type TotalGiven = PublicTypes.TotalDeclaration
type QuantityGiven = PublicTypes.QuantityDeclaration

local AnyValue = Check.AnyValue
local BalancePath = Rules.BalancePath
local Copied = Rules.Copied
local NoFields = Rules.NoFields
local OpKindName = Rules.OpKindName
local OpPath = Rules.OpPath
local OrDefault = Rules.OrDefault
local Plain = Rules.Plain
local QuantityPath = Rules.QuantityPath
local Validated = Rules.Validated
local WindowPath = Rules.WindowPath

local NonEmptyText = Check.TextAtLeast(1)

local KeysModes = ShellSetup.KeysMode
local KeyKinds = Record.KeyKind

local WholeMost = Record.VarintLimit - 1

local DefaultWhere = "Default"
local ReservedStoreName = `a store name other than "{Record.CounterStore}", which Ledger keeps for its server counter`
local DefaultTooBig = `a state of at most {Record.StateCap} bytes as canonical JSON`
local KindsWanted = "an op kind name, or a list of names and { Kind, Min?, Max? } tables"
local KindOnceWanted = "a kind named once in Balances, under one field and one of Credit or Debit"
local MockWanted = "a service that Mock.New made"
local ErasableWanted = "true or false, which says whether Store:Erase may end this store's keys "
	.. "(true gives them the incarnation id an erase needs, false makes Erase throw)"

local function MigrationPath(Where: string, Index: number): string
	return `{Where} Migrations[{Index}]`
end

local function TotalPath(Where: string, Name: string): string
	return `{Where} Totals.{Name}`
end

local function SerialsPath(Where: string): string
	return `{Where} Serials`
end

local NoItems: { unknown } = {}
table.freeze(NoItems)
local NoNames: { string } = {}
table.freeze(NoNames)

local StoreNameBytes = Check.Text(1, Record.StoreNameBytesMost)
local StringKeys = Plain(Check.Map(NonEmptyText, AnyValue))
local KeyName = Check.Text(1, Record.KeyNameBytesMost)

local function StoreName(Value: unknown): string?
	if Value == Record.CounterStore then
		return ReservedStoreName
	end
	return StoreNameBytes(Value)
end

local function DefaultState(Value: unknown): string?
	local Problem = StringKeys(Value)
	if Problem ~= nil then
		return Problem
	end
	local Unstorable = Guards.Storable(Value, DefaultWhere)
	if Unstorable ~= nil then
		return Rules.StorableWanted(Unstorable)
	end
	if Json.Size(Value) > Record.StateCap then
		return DefaultTooBig
	end
	return nil
end

local function KindItemShape(Value: unknown): string?
	if type(Value) == "table" then
		return nil
	end
	return OpKindName(Value)
end

local KindList = Plain(Check.List(KindItemShape))

local function KindNames(Value: unknown): string?
	if type(Value) == "string" then
		return OpKindName(Value)
	end
	if type(Value) == "table" then
		return KindList(Value)
	end
	return KindsWanted
end

local function MockService(Value: unknown): string?
	if type(Value) == "table" then
		return nil
	end
	return MockWanted
end

local function ErasableDeclared(Value: unknown): string?
	if type(Value) == "boolean" then
		return nil
	end
	return ErasableWanted
end

local PlayerRules: { [string]: Rule } = {
	Name = StoreName,
	Keys = Check.OneOf(KeysModes.Player, KeysModes.String),
	Default = DefaultState,
	Reducer = Check.Optional(Check.Function),
	Schema = Check.Optional(Check.Function),
	Balances = Check.Optional(Plain(Check.Map(NonEmptyText, AnyValue))),
	Migrations = Check.Optional(Plain(Check.ListAtMost(AnyValue, Record.MigrationsMax))),
	MustExist = Check.Boolean,
	Erasable = ErasableDeclared,
	LegLimit = Check.Optional(Settable.LegLimit.Rule),
	OnLoadFailed = Check.Optional(Check.Function),
	Kick = Check.Optional(Settable.Kick.Rule),
	KickMessage = Check.Optional(Settable.KickMessage.Rule),
	SaveInterval = Check.Optional(Settable.SaveInterval.Rule),
	IdleReadInterval = Check.Optional(Settable.IdleReadInterval.Rule),
	HoldMax = Check.Optional(Settable.HoldMax.Rule),
	OrphanAge = Check.Optional(Settable.OrphanAge.Rule),
	Windows = Check.Optional(Plain(Check.Map(NonEmptyText, AnyValue))),
	CutWindow = Check.Optional(Settable.CutWindow.Rule),
	Totals = Check.Optional(Plain(Check.Map(KeyName, AnyValue))),
	Quantities = Check.Optional(Plain(Check.Map(KeyName, AnyValue))),
	Mock = Check.Optional(MockService),
}

local EntityRules = table.clone(PlayerRules)
EntityRules.OnLoadFailed = nil
EntityRules.Kick = nil
EntityRules.KickMessage = nil

local KindRules: { [string]: Rule } = {
	Kind = OpKindName,
	Min = AnyValue,
	Max = AnyValue,
}

local FieldRules: { [string]: Rule } = {
	Credit = Check.Optional(KindNames),
	Debit = Check.Optional(KindNames),
	Min = AnyValue,
	Max = AnyValue,
	Arithmetic = AnyValue,
}

local AdditiveMigrationRules: { [string]: Rule } = {
	Run = Check.Function,
	IsBreaking = Check.Optional(Check.Boolean),
	Fields = Plain(Check.List(NonEmptyText)),
}

local BreakingMigrationRules: { [string]: Rule } = {
	Run = Check.Function,
	IsBreaking = Check.Boolean,
}

local WindowRules: { [string]: Rule } = {
	Timed = Check.Optional(Settable.TimedWindow.Rule),
	Untimed = Check.Optional(Settable.UntimedWindow.Rule),
}

local TotalRules: { [string]: Rule } = {
	Shards = Check.Optional(Check.Whole(1, Extras.ShardsMost)),
}

local QuantityRules: { [string]: Rule } = {
	Parts = Check.Whole(Hot.PartsLeast, Hot.PartsMost),
	Mode = Check.OneOf(Hot.Mode.Final, Hot.Mode.Open),
	Stock = Check.Optional(Check.Whole(0, WholeMost)),
	Serials = AnyValue,
	Proceeds = Check.Optional(Plain(Check.ListAtMost(NonEmptyText, Hot.ProceedsMax))),
	Closed = Check.Optional(Check.Boolean),
}

local SerialsRules: { [string]: Rule } = {
	First = Check.Whole(0, WholeMost - 1),
	Count = Check.Whole(1, WholeMost),
}

local function FrozenCopy<Item>(List: { Item }): { Item }
	local Copy = table.clone(List)
	table.freeze(Copy)
	return Copy
end

local function KindListOf(Value: (string | { KindItem })?): { KindItem }
	if Value == nil then
		return NoItems :: { KindItem }
	end
	if type(Value) == "string" then
		return { Value }
	end
	return Value
end

local function KindOf(Item: KindItem, Given: FieldGiven, Where: string): KindGiven
	if type(Item) == "string" then
		return { Kind = Item, Min = Given.Min, Max = Given.Max }
	end
	local Own = Validated(Item, KindRules, Where) :: KindGiven
	return {
		Kind = Own.Kind,
		Min = if Own.Min == nil then Given.Min else Own.Min,
		Max = if Own.Max == nil then Given.Max else Own.Max,
	}
end

local Repeated = Rules.Equals(false, KindOnceWanted)

local function NamedOnce(Seen: { [string]: true }, OpKind: string, Where: string): ()
	if Seen[OpKind] then
		Check.Table({ Kind = OpKind }, { Kind = Repeated }, Where)
	end
	Seen[OpKind] = true
end

local function SettleKinds(Given: FieldGiven, Field: string, Direction: Direction, Settled: Settling, Where: string): ()
	local Names = if Direction == Balances.Direction.Credit then Given.Credit else Given.Debit
	for Index, Item in KindListOf(Names) do
		local Own = KindOf(Item, Given, `{BalancePath(Where, Field)}.{Direction}[{Index}]`)
		local Path = OpPath(Where, Own.Kind)
		NamedOnce(Settled.Seen, Own.Kind, Path)
		local Kind = {
			Field = Field,
			Direction = Direction,
			Min = Own.Min,
			Max = Own.Max,
			Arithmetic = Given.Arithmetic,
		}
		Settled.Ops[Own.Kind] = Balance.Settle(Kind, Settled.Copies, Settled.Listed, Path)
	end
end

local function BalancesOf(Given: Named?, Copies: Balance.Copies, Where: string): (Balance.Listed, Ops)
	local Fields: { [string]: FieldGiven } = {}
	local Listed: Balance.Listed = {}
	for Field, Entry in OrDefault(Given, NoFields) do
		local Path = BalancePath(Where, Field)
		local Declared = Validated(Entry, FieldRules, Path) :: FieldGiven
		Fields[Field] = Declared
		Listed[Field] = Balance.ListedArithmetic(OrDefault(Declared.Arithmetic, true), Copies, Path)
	end
	table.freeze(Listed)

	local Settled: Settling = { Listed = Listed, Ops = {}, Seen = {}, Copies = Copies }
	for Field, Entry in Fields do
		SettleKinds(Entry, Field, Balances.Direction.Credit, Settled, Where)
		SettleKinds(Entry, Field, Balances.Direction.Debit, Settled, Where)
	end
	return Listed, table.freeze(Settled.Ops)
end

local function MigrationRulesOf(Given: Named): { [string]: Rule }
	if Given.IsBreaking == true then
		return BreakingMigrationRules
	end
	return AdditiveMigrationRules
end

local function MigrationsOf(Given: { unknown }?, Where: string): { SettledMigration }
	local Settled: { SettledMigration } = {}
	for Index, Item in OrDefault(Given, NoItems) do
		local Path = MigrationPath(Where, Index)
		local Copy = Copied(Item, Path) :: Named
		Check.Table(Copy, MigrationRulesOf(Copy), Path)
		local Migration = Copy :: MigrationGiven
		table.insert(
			Settled,
			table.freeze({
				Run = Migration.Run,
				IsBreaking = Migration.IsBreaking == true,
				Fields = FrozenCopy(OrDefault(Migration.Fields, NoNames)),
			})
		)
	end
	return table.freeze(Settled)
end

local function WindowsOf(Given: Named?, Where: string): { [string]: KindWindows }
	local Declared = OrDefault(Given, NoFields)
	Check.Table({ Windows = Declared }, { Windows = Check.Map(OpKindName, AnyValue) }, Where)

	local Settled: { [string]: KindWindows } = {}
	for OpKind, Entry in Declared do
		local Path = WindowPath(Where, OpKind)
		local Window = Validated(Entry, WindowRules, Path) :: WindowGiven
		local Timed = OrDefault(Window.Timed, Settable.TimedWindow.Default)
		Settled[OpKind] = table.freeze({
			Timed = Timed,
			Untimed = OrDefault(Window.Untimed, Timed),
			IsUntimedSet = Window.Untimed ~= nil,
		})
	end
	return table.freeze(Settled)
end

local function TotalsOf(Given: Named?, Where: string): { [string]: ExtrasShapes.TotalDeclaration }
	local Settled: { [string]: ExtrasShapes.TotalDeclaration } = {}
	for Name, Entry in OrDefault(Given, NoFields) do
		local Total = Validated(Entry, TotalRules, TotalPath(Where, Name)) :: TotalGiven
		local Shards = OrDefault(Total.Shards, Extras.ShardsDefault)
		Settled[Name] = table.freeze({ Name = Name, KeyCount = Shards, Keys = KeyKinds.Shard })
	end
	return table.freeze(Settled)
end

local function SerialsOf(Value: unknown, Where: string): Serials?
	if Value == nil then
		return nil
	end
	local Path = SerialsPath(Where)
	local Given = Validated(Value, SerialsRules, Path) :: Serials
	local CountMost = WholeMost - Given.First
	Check.Table({ Count = Given.Count }, { Count = Check.Whole(1, CountMost) }, Path)
	return { First = Given.First, Count = Given.Count }
end

local function QuantitiesOf(
	Given: Named?,
	Where: string
): ({ [string]: HotShapes.QuantityDeclaration }, { [string]: boolean })
	local Settled: { [string]: HotShapes.QuantityDeclaration } = {}
	local Closed: { [string]: boolean } = {}
	for Name, Entry in OrDefault(Given, NoFields) do
		local Path = QuantityPath(Where, Name)
		local Quantity = Validated(Entry, QuantityRules, Path) :: QuantityGiven
		Settled[Name] = table.freeze({
			Name = Name,
			Parts = Quantity.Parts,
			Mode = Quantity.Mode,
			Stock = Quantity.Stock,
			Serials = SerialsOf(Quantity.Serials, Path),
			Proceeds = FrozenCopy(OrDefault(Quantity.Proceeds, NoNames)),
		})
		Closed[Name] = Quantity.Closed == true
	end
	return table.freeze(Settled), table.freeze(Closed)
end

local function RulesFor(Given: Named): { [string]: Rule }
	if Given.Keys == KeysModes.String then
		return EntityRules
	end
	return PlayerRules
end

local function Settle(Options: unknown, Where: string): Settings
	local Copy = Copied(Options, Where) :: Named
	Check.Table(Copy, RulesFor(Copy), Where)
	local Given = Copy :: OptionsGiven

	local Default = Guards.DeepCopy(Given.Default :: Tree) :: Named
	local Migrations = MigrationsOf(Given.Migrations, Where)
	local Windows = WindowsOf(Given.Windows, Where)
	local Totals = TotalsOf(Given.Totals, Where)
	local Quantities, ClosedQuantities = QuantitiesOf(Given.Quantities, Where)
	local Copies: Balance.Copies = {}
	local Listed, Ops = BalancesOf(Given.Balances, Copies, Where)
	Guards.DeepFreeze(Default)

	return table.freeze({
		Name = Given.Name,
		Keys = Given.Keys,
		Default = Default,
		Reducer = Given.Reducer,
		Schema = Given.Schema,
		Ops = Ops,
		Balances = Listed,
		Migrations = Migrations,
		MustExist = Given.MustExist,
		IsErasable = Given.Erasable,
		LegLimit = Given.LegLimit,
		OnLoadFailed = Given.OnLoadFailed,
		Kick = OrDefault(Given.Kick, Settable.Kick.Default),
		KickMessage = OrDefault(Given.KickMessage, Settable.KickMessage.Default),
		SaveInterval = OrDefault(Given.SaveInterval, Settable.SaveInterval.Default),
		IdleReadInterval = OrDefault(Given.IdleReadInterval, Settable.IdleReadInterval.Default),
		HoldMax = OrDefault(Given.HoldMax, Settable.HoldMax.Default),
		OrphanAge = OrDefault(Given.OrphanAge, Settable.OrphanAge.Default),
		Windows = Windows,
		CutWindow = OrDefault(Given.CutWindow, Settable.CutWindow.Default),
		Totals = Totals,
		Quantities = Quantities,
		ClosedQuantities = ClosedQuantities,
		Mock = Given.Mock,
	})
end

return {
	Settle = Settle,
}
