--!strict
--!optimize 2

--[=[
	KeyLegs: the key leg a quantity's move builds for a key the game names as a plain { Store, Key } (hot keys H8, A11):
	the balance kind its store declares in that direction on the field, or the one Kind names among several, and its
	amount. A leg is checked against its key's own setup, a part's included.

	Return type: A plain table with BalanceLeg and CheckedOf.
	Example usage:
		local Credit = KeyLegs.BalanceLeg(To, "To", "Coins", nil, "Credit", 5, "Quantity:Withdraw")
--]=]

local Balance = require("./Balance")
local Balances = require("../../Tx/Legs/Balances")
local Cache = require("../../Reading/Cache")
local Check = require("../../Encoding/Check")
local Keys = require("./Keys")
local KindSetup = require("../../Judging/KindSetup")
local Leg = require("./Leg")
local Rules = require("./Rules")
local Runner = require("../../Shell/Runner")
local ShellSetup = require("../../Shell/Setup")
local Stores = require("./Stores")
local TxShapes = require("../../Tx/Shapes")

type CheckedLeg = Leg.CheckedLeg
type Direction = Balances.Direction
type Rule = Check.Rule
type Settings = ShellSetup.Settings
type TxLeg = TxShapes.TxLeg

type KeyGiven = { Store: unknown, Key: unknown }

local CheckAccepted = "KeyLegs: a Check rule accepted a value of another type. The rule must reject it"

local KeyRules: { [string]: Rule } = {
	Store = Leg.MadeStore,
	Key = Check.AnyValue,
}

local function KindOnWanted(Store: string, Direction: Direction): string
	return `a balance field on which the store "{Store}" declares a {Direction} kind in Ops`
end

local function KindsOn(Settings: Settings, Field: string, Direction: Direction): { string }
	local Found: { string } = {}
	for OpKind, Kind in ShellSetup.BalanceOpsOf(Settings) do
		if Kind.Field == Field and Kind.Direction == Direction then
			table.insert(Found, OpKind)
		end
	end
	return Found
end

local function KindOn(Settings: Settings, Direction: Direction): Rule
	local Wanted = KindOnWanted(Settings.Name, Direction)
	return function(Value: unknown): string?
		if type(Value) == "string" and #KindsOn(Settings, Value, Direction) > 0 then
			return nil
		end
		return Wanted
	end
end

local function KindChoice(Choices: { string }): Rule
	local Named = Check.OneOf(table.unpack(Choices))
	if #Choices == 1 then
		return Check.Optional(Named)
	end
	return Named
end

local function CheckedOf(Leg: TxLeg, Settings: Settings): CheckedLeg
	local Setup = KindSetup.SetupFor(Runner.OpenedSetup(Settings.Name), Cache.KindOfKey(Leg.Key))
	return { Leg = Leg, Settings = Settings, Setup = Setup }
end

local function BalanceLeg(
	Value: unknown,
	Option: string,
	Field: unknown,
	Kind: unknown,
	Direction: Direction,
	Amount: unknown,
	Where: string
): CheckedLeg
	Check.Table({ [Option] = Value }, { [Option] = Rules.NoMetatable }, Where)
	local KeyWhere = `{Where} {Option}`
	local Given = Rules.Validated(Value, KeyRules, KeyWhere) :: KeyGiven
	local Settings = Stores.SettingsOf(Given.Store)
	assert(Settings ~= nil, CheckAccepted)
	local Key = Keys.Key(Settings, Given.Key, KeyWhere)
	Check.Table({ Field = Field }, { Field = KindOn(Settings, Direction) }, Where)
	assert(type(Field) == "string", CheckAccepted)
	local Choices = KindsOn(Settings, Field, Direction)
	table.sort(Choices)
	Check.Table({ Kind = Kind }, { Kind = KindChoice(Choices) }, Where)
	local OpKind = Choices[1]
	if Kind ~= nil then
		assert(type(Kind) == "string", CheckAccepted)
		OpKind = Kind
	end
	local Arithmetic = Balances.ArithmeticOf(ShellSetup.BalanceOpsOf(Settings)[OpKind])
	Check.Table({ Count = Amount }, { Count = Balance.IsCallAmountOf(Arithmetic) }, Where)
	local Leg: TxLeg = {
		Key = Key,
		OpKind = OpKind,
		Terms = { Kind = OpKind, Amount = Amount },
		MustExist = nil,
		Slot = nil,
	}
	return CheckedOf(Leg, Settings)
end

return {
	BalanceLeg = BalanceLeg,
	CheckedOf = CheckedOf,
}
