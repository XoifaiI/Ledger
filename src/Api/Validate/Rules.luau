--!strict
--!optimize 2

--[=[
	Rules: the rules Api/Validate's modules share and Check lacks, among them the plain-table rule, Schema at a call
	and a window's bound below OrphanAge (transaction sheet 2). A game's table with a metatable is refused unread;
	Copied and Validated give a raw copy and FrozenAmount a deep frozen one, which the caller reads instead.

	Return type: A plain table with NoMetatable, Plain, Copied, Validated, FrozenAmount, OrDefault, NoFields, Equals,
	LeftOut, DeclaredKind, StorableWanted, StorableAs, CheckSchema, OpPath, OpWhere, BalancePath, WindowPath,
	QuantityPath, WindowBoundOf and IsBelowWindowBound.
	Example usage:
		local Given = Rules.Validated(Entry, TotalRules, Where) :: TotalGiven
		local Shards = Rules.OrDefault(Given.Shards, 16)
--]=]

local Check = require("../../Encoding/Check")
local Guards = require("../../Judging/Guards")
local Record = require("../../Constants/Record")
local ShellSetup = require("../../Shell/Setup")
local Stepping = require("../../Shell/Stepping")
local Transaction = require("../../Constants/Transaction")

type Rule = Check.Rule
type ResultSchema = ShellSetup.ResultSchema<unknown>
type Settings = ShellSetup.Settings

type Named = { [string]: unknown }
type Terms = { [unknown]: unknown }

local CheckAcceptedNonTable = "Rules: Check.Table accepted a value that is not a table. Check.Table must reject it"
local DeclaredKindWanted = "an op kind declared in Ops"
local SchemaYielded = "a yield, and Schema must complete without yielding"
local TableWanted = "a table"
local PlainWanted = "a table with no metatable"
local OptionsLabel = "options"

local NoFields: Named = {}
table.freeze(NoFields)

local function OpPath(Where: string, OpKind: string): string
	return `{Where} Ops.{OpKind}`
end

local function OpWhere(Where: string): string
	return `{Where} Op`
end

local function BalancePath(Where: string, Field: string): string
	return `{Where} Balances.{Field}`
end

local function WindowPath(Where: string, OpKind: string): string
	return `{Where} Windows.{OpKind}`
end

local function QuantityPath(Where: string, Name: string): string
	return `{Where} Quantities.{Name}`
end

local function SchemaThrew(Problem: unknown): string
	return `a throw: {Problem}`
end

local function MustPassSchema(Where: string, Option: string, Problem: string): string
	return `{Where}: {Option} must pass Schema, got {Problem}`
end

local function StorableWanted(Problem: string): string
	return `a table of storable values, but {Problem}`
end

local function StorableAs(Option: string): Rule
	return function(Value: unknown): string?
		local Problem = Guards.Storable(Value, Option)
		if Problem == nil then
			return nil
		end
		return StorableWanted(Problem)
	end
end

local function Equals(Wanted: unknown, Text: string): Rule
	return function(Value: unknown): string?
		if Value == Wanted then
			return nil
		end
		return Text
	end
end

local function LeftOut(Wanted: string): Rule
	return function(Value: unknown): string?
		if Value == nil then
			return nil
		end
		return Wanted
	end
end

local function WindowBoundOf(Settings: Settings): number
	return Settings.OrphanAge - Transaction.WindowSigmasBelowOrphanAge * Record.Sigma
end

local function IsBelowWindowBound(Window: number, Settings: Settings): boolean
	return Window < WindowBoundOf(Settings)
end

local function DeclaredKind(Ops: { read [string]: unknown }): Rule
	return function(Value: unknown): string?
		if type(Value) == "string" and Ops[Value] ~= nil then
			return nil
		end
		return DeclaredKindWanted
	end
end

local function OrDefault<Item>(Value: Item?, Default: Item): Item
	if Value == nil then
		return Default
	end
	return Value
end

local function Plain(Item: Rule): Rule
	return function(Value: unknown): string?
		if type(Value) == "table" and getmetatable(Value) ~= nil then
			return PlainWanted
		end
		return Item(Value)
	end
end

local function AnyTable(Value: unknown): string?
	if type(Value) == "table" then
		return nil
	end
	return TableWanted
end

local NoMetatable = Plain(Check.AnyValue)
local PlainOptions = Plain(AnyTable)

local function Copied(Value: unknown, Where: string): Terms
	Check.Table({ [OptionsLabel] = Value }, { [OptionsLabel] = PlainOptions }, Where)
	assert(type(Value) == "table", CheckAcceptedNonTable)
	return table.clone(Value :: Terms)
end

local function Validated(Value: unknown, Rules: { [string]: Rule }, Where: string): Terms
	local Given = Copied(Value, Where)
	Check.Table(Given, Rules, Where)
	return Given
end

local function FrozenAmount(Amount: unknown, Option: string, Where: string): unknown
	if type(Amount) ~= "table" then
		return Amount
	end
	Check.Table({ [Option] = Amount }, { [Option] = StorableAs(Option) }, Where)
	local Copy = Guards.DeepCopy(Amount :: Terms)
	Guards.DeepFreeze(Copy)
	return Copy
end

local function SchemaProblemAtCall(Schema: ResultSchema, State: unknown): string?
	local Ran = Guards.RunWithoutYield(ShellSetup.SchemaProblem, SchemaYielded, Schema, State)
	if Ran.Kind == "Threw" then
		return SchemaThrew(Ran.Problem)
	end
	if Ran.Kind == "Yielded" then
		return SchemaYielded
	end
	return Ran.Value
end

local function CheckSchema(Schema: ResultSchema?, Option: string, State: unknown, Where: string): ()
	if Schema == nil then
		return
	end
	local Problem = Stepping.Run(SchemaProblemAtCall, Schema, State)
	if Problem ~= nil then
		error(MustPassSchema(Where, Option, Problem), 0)
	end
end

return {
	NoMetatable = NoMetatable,
	Plain = Plain,
	Copied = Copied,
	Validated = Validated,
	FrozenAmount = FrozenAmount,
	OrDefault = OrDefault,
	NoFields = NoFields,
	Equals = Equals,
	LeftOut = LeftOut,
	DeclaredKind = DeclaredKind,
	StorableWanted = StorableWanted,
	StorableAs = StorableAs,
	CheckSchema = CheckSchema,
	OpPath = OpPath,
	OpWhere = OpWhere,
	BalancePath = BalancePath,
	WindowPath = WindowPath,
	QuantityPath = QuantityPath,
	WindowBoundOf = WindowBoundOf,
	IsBelowWindowBound = IsBelowWindowBound,
}
