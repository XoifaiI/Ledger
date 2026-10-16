--!strict
--!optimize 2

--[=[
	Setup: a store's Settings, scope, part build, Build and core Setup. The reducer runs the game's (thrice in Studio,
	compared), warning once per undeclared field, then Schema on a table result; a fail warns, unsaved. Schema skips
	migrations' outputs, older builds' states and balance ops'. Of its own game keys, a player store's builds reference
	only UserIds. OnLoadFailed keeps Kick.

	Return type: A plain table with StoreScope, KeysMode, BalanceOpsOf, FieldArithmeticsOf, DeclaredOf, FrozenInputs,
	SchemaProblem, IsUserIdKey, PartBuildOf and SetupOf, and the Settings types.
	Example usage:
		local PartBuild = Setup.PartBuildOf(Settings)
		local StoreSetup = Setup.SetupOf(Settings, PartBuild, Encoding, Limits, IsStudio)
--]=]

local Balances = require("../Tx/Legs/Balances")
local Cache = require("../Reading/Cache")
local ExtrasShapes = require("../Extras/Shapes")
local Guards = require("../Judging/Guards")
local HashInputs = require("../Encoding/HashInputs")
local HotShapes = require("../Hot/Shapes")
local Names = require("../Encoding/Names")
local PartBuilder = require("../Hot/Part/Build")
local Reasons = require("../Constants/Reasons")
local Record = require("../Constants/Record")
local Shapes = require("../Shapes")

type Arithmetic = Balances.Arithmetic
type Build = Shapes.Build
type Declaration = Balances.Declaration
type Encoding = HashInputs.Encoding
type KeyReference = Names.KeyReference
type Limits = Shapes.Limits
type Migration = Shapes.Migration
type QuantityDeclaration = HotShapes.QuantityDeclaration
type Reason = Reasons.Reason
type Reducer = Guards.Reducer<unknown, unknown, unknown>
type Setup = Shapes.Setup
type TotalDeclaration = ExtrasShapes.TotalDeclaration

type Terms = { [unknown]: unknown }

local KeysMode = {
	Player = "Player" :: "Player",
	String = "String" :: "String",
}

export type KeysMode = keyof<typeof(KeysMode)>

export type LoadFailedHandler = (Player: Player, Reason: Reason) -> ()

export type ResultSchema<D> = (State: D) -> (boolean, string?)

export type KindWindows = {
	read Timed: number,
	read Untimed: number,
	read IsUntimedSet: boolean,
}

export type SettledMigration = {
	read Run: Guards.MigrationRun,
	read IsBreaking: boolean,
	read Fields: { string },
}

export type Ops = { [string]: Declaration }

export type Settings = {
	read Name: string,
	read Keys: KeysMode,
	read Default: { [string]: unknown },
	read Reducer: Reducer?,
	read Schema: ResultSchema<unknown>?,
	read Ops: Ops,
	read Balances: { [string]: Arithmetic },
	read Migrations: { SettledMigration },
	read MustExist: boolean,
	read IsErasable: boolean,
	read LegLimit: number?,
	read OnLoadFailed: LoadFailedHandler?,
	read Kick: boolean,
	read KickMessage: string,
	read SaveInterval: number,
	read IdleReadInterval: number,
	read HoldMax: number,
	read OrphanAge: number,
	read Windows: { [string]: KindWindows },
	read CutWindow: number,
	read Totals: { [string]: TotalDeclaration },
	read Quantities: { [string]: QuantityDeclaration },
	read ClosedQuantities: { [string]: boolean },
	read Mock: unknown?,
}

local StoreScope = "global"

local KeyKinds = Record.KeyKind

local FrozenInputs: Guards.FreezeLimits = table.freeze({ FreezeInputs = true })

local SchemaGaveFalse = "false"
local StateNotSaved = "the reducer's state fails Schema, so it is not saved"
local OnlyDeclaredFields = "A reducer may set only the fields in Default or an additive migration's Fields, and a "
	.. 'field that is nil in Default is not one of them. Give "none" a value such as 0 or "" in Default'

local function DifferentRuns(Store: string, OpKind: string, Difference: string): string
	return `Ledger: store {Store}, an op of kind {OpKind}: {Difference}`
end

local function SchemaFailed(Store: string, OpKind: string, Problem: string): string
	return `Ledger: store {Store}, an op of kind {OpKind}: {StateNotSaved}: {Problem}`
end

local function UndeclaredHeld(Store: string, OpKind: string, Held: string): string
	return `Ledger: store {Store}, an op of kind {OpKind}: the reducer gave a state holding {Held}, which the store `
		.. `does not declare, and such a state is refused. {OnlyDeclaredFields}`
end

local function HeldText(Key: unknown): string
	if type(Key) == "string" then
		return `the field {Key}`
	end
	return `a {typeof(Key)} key`
end

local function RefuseEveryOp(State: unknown, Op: unknown): unknown?
	return nil
end

local function KindOf(Op: unknown): string
	if type(Op) ~= "table" then
		return tostring(Op)
	end
	return tostring((Op :: Terms).Kind)
end

local function TwiceRun(Reducer: Reducer, Store: string): Reducer
	return function(State: unknown, Op: unknown): unknown?
		local First = Guards.RunReducer(Reducer, State, Op, FrozenInputs)
		local Second = Guards.RunReducer(Reducer, State, Op, FrozenInputs)
		local Difference = Guards.CompareRuns(First, Second)
		if Difference ~= nil then
			warn(DifferentRuns(Store, KindOf(Op), Difference))
		end
		return Reducer(State, Op)
	end
end

local function UndeclaredWarned(Reducer: Reducer, Declared: { [string]: boolean }, Store: string): Reducer
	local Warned: { [string]: boolean } = {}
	return function(State: unknown, Op: unknown): unknown?
		local Result = Reducer(State, Op)
		if type(Result) ~= "table" then
			return Result
		end
		for Key in next, Result :: Terms do
			if type(Key) == "string" and Declared[Key] then
				continue
			end
			local Held = HeldText(Key)
			if not Warned[Held] then
				Warned[Held] = true
				warn(UndeclaredHeld(Store, KindOf(Op), Held))
			end
		end
		return Result
	end
end

local function SchemaProblem(Schema: ResultSchema<unknown>, State: unknown): string?
	local Passes, Message = Schema(State)
	if Passes == true then
		return nil
	end
	if Message == nil then
		return SchemaGaveFalse
	end
	return Message
end

local function SchemaChecked(Reducer: Reducer, Schema: ResultSchema<unknown>, Store: string): Reducer
	return function(State: unknown, Op: unknown): unknown?
		local Result = Reducer(State, Op)
		if type(Result) ~= "table" then
			return Result
		end
		local Problem = SchemaProblem(Schema, Result)
		if Problem == nil then
			return Result
		end
		warn(SchemaFailed(Store, KindOf(Op), Problem))
		return nil
	end
end

local function ReducerOf(Settings: Settings, Declared: { [string]: boolean }, IsStudio: boolean): Reducer
	local Reducer = Settings.Reducer
	if Reducer == nil then
		return RefuseEveryOp
	end
	local Watched = UndeclaredWarned(Reducer, Declared, Settings.Name)
	local Run = if IsStudio then TwiceRun(Watched, Settings.Name) else Watched
	local Schema = Settings.Schema
	if Schema == nil then
		return Run
	end
	return SchemaChecked(Run, Schema, Settings.Name)
end

local function MigrationsOf(Settled: { SettledMigration }): { Migration }
	local Runs: { Migration } = {}
	for _, Migration in Settled do
		table.insert(Runs, table.freeze({ Run = Migration.Run, IsBreaking = Migration.IsBreaking }))
	end
	return table.freeze(Runs)
end

local function BreakingIndexOf(Settled: { SettledMigration }): number
	local Last = 0
	for Index, Migration in Settled do
		if Migration.IsBreaking then
			Last = Index
		end
	end
	return Last
end

local function DeclaredOf(Settings: Settings): { [string]: boolean }
	local Declared: { [string]: boolean } = {}
	for Field in Settings.Default do
		Declared[Field] = true
	end
	for _, Migration in Settings.Migrations do
		for _, Field in Migration.Fields do
			Declared[Field] = true
		end
	end
	return table.freeze(Declared)
end

local function BalanceOpsOf(Settings: Settings): { [string]: Declaration }
	return Settings.Ops
end

local function FieldArithmeticsOf(Settings: Settings): { [string]: Arithmetic }
	local Fields: { [string]: Arithmetic } = table.clone(Settings.Balances)
	for _, Kind in Settings.Ops do
		if Fields[Kind.Field] ~= nil then
			continue
		end
		Fields[Kind.Field] = Balances.ArithmeticOf(Kind)
	end
	return table.freeze(Fields)
end

local function IsUserIdKey(Key: string): boolean
	return tonumber(Key) ~= nil
end

local function PlayerStoreReferences(Store: string): (Reference: KeyReference) -> boolean
	return function(Reference: KeyReference): boolean
		if Reference.Kind == "Full" and Reference.Store ~= Store then
			return true
		end
		local Named = { Store = Store, Scope = StoreScope, Key = Reference.Key }
		return Cache.KindOfKey(Named) ~= KeyKinds.Game or IsUserIdKey(Reference.Key)
	end
end

local function ReferencesOf(Settings: Settings): ((Reference: KeyReference) -> boolean)?
	if Settings.Keys ~= KeysMode.Player then
		return nil
	end
	return PlayerStoreReferences(Settings.Name)
end

local function PartBuildOf(Settings: Settings): Build
	return PartBuilder.NewBuild(FieldArithmeticsOf(Settings), ReferencesOf(Settings))
end

local function BuildOf(Settings: Settings, IsStudio: boolean): Build
	local Kinds = BalanceOpsOf(Settings)
	local Declared = DeclaredOf(Settings)
	return table.freeze({
		KeyKind = KeyKinds.Game,
		Migrations = MigrationsOf(Settings.Migrations),
		MigrationCount = #Settings.Migrations,
		BreakingIndex = BreakingIndexOf(Settings.Migrations),
		Reducer = ReducerOf(Settings, Declared, IsStudio),
		Default = Settings.Default,
		Declared = Declared,
		Balances = FieldArithmeticsOf(Settings),
		BalanceOps = Kinds,
		MayReference = ReferencesOf(Settings),
	})
end

local function SetupOf(
	Settings: Settings,
	PartBuild: Build,
	Encoding: Encoding,
	Limits: Limits,
	IsStudio: boolean
): Setup
	return table.freeze({
		Store = Settings.Name,
		Build = BuildOf(Settings, IsStudio),
		Limits = Limits,
		Encoding = Encoding,
		IsErasable = Settings.IsErasable,
		CreatesOnFirstWrite = not Settings.MustExist,
		PartBuild = PartBuild,
	})
end

return {
	StoreScope = StoreScope,
	KeysMode = table.freeze(KeysMode),
	FrozenInputs = FrozenInputs,
	SchemaProblem = SchemaProblem,
	IsUserIdKey = IsUserIdKey,
	BalanceOpsOf = BalanceOpsOf,
	FieldArithmeticsOf = FieldArithmeticsOf,
	DeclaredOf = DeclaredOf,
	PartBuildOf = PartBuildOf,
	SetupOf = SetupOf,
}
