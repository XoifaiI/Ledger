--!strict
--!optimize 2

--[=[
	Leg: one leg the game names (transaction sheet 7 step 1, A11): a plain table, its store one Ledger.New made on
	this server, its key and its op, which the Tx or call names. A Tx leg takes no slot; a quantity's leg takes one
	only when a serial part decides, never on a balance kind (hot keys 2.7).

	Return type: A plain table with MadeStore, TxLegOf and TakeLeg, and the CheckedLeg type.
	Example usage:
		local Checked = Leg.TxLegOf(Given, "Ledger.Tx Legs[1]")
--]=]

local Args = require("./Args")
local Check = require("../../Encoding/Check")
local HotShapes = require("../../Hot/Shapes")
local Keys = require("./Keys")
local Post = require("../../Stored/Post")
local Record = require("../../Constants/Record")
local Requests = require("../../Tx/Call/Requests")
local Rules = require("./Rules")
local Runner = require("../../Shell/Runner")
local Shapes = require("../../Shapes")
local ShellSetup = require("../../Shell/Setup")
local SlotPath = require("../../Stored/Items/SlotPath")
local Stores = require("./Stores")
local TxShapes = require("../../Tx/Shapes")

type PathStep = Post.PathStep
type QuantityDeclaration = HotShapes.QuantityDeclaration
type Rule = Check.Rule
type Settings = ShellSetup.Settings
type Setup = Shapes.Setup
type TxLeg = TxShapes.TxLeg

type LegGiven = { Store: unknown, Key: unknown, Op: unknown, MustExist: boolean?, Slot: unknown }

export type CheckedLeg = {
	read Leg: TxLeg,
	read Settings: Settings,
	read Setup: Setup,
}

local AnyValue = Check.AnyValue
local LeftOut = Rules.LeftOut
local NoMetatable = Rules.NoMetatable
local Validated = Rules.Validated

local CheckAccepted = "Leg: a Check rule accepted a value of another type. The rule must reject it"
local StoreWanted = "a store object that Ledger.New opened on this server"
local LegOption = "Leg"
local NoSlot = "nil, since only a serial part decides a slot, and a Tx never has a part leg"
local NoSlotUnlessSerial = "nil, since only a serial part decides a slot, and this quantity has no serials"
local NoSlotOnDelta = "nil, since a balance kind's leg takes no slot"
local SlotWanted = "an array with no metatable of one or more steps, each a string of at least 1 byte of valid UTF-8 "
	.. `or a whole number from {Post.FirstIndex} to {Record.VarintLimit - 1}`

local function MadeStore(Value: unknown): string?
	if Stores.SettingsOf(Value) == nil then
		return StoreWanted
	end
	return nil
end

local function SlotPathRule(Value: unknown): string?
	if type(Value) == "table" and getmetatable(Value) == nil and SlotPath.IsSlotPath(Value) then
		return nil
	end
	return SlotWanted
end

local function LegRulesWith(Slot: Rule): { [string]: Rule }
	return {
		Store = MadeStore,
		Key = AnyValue,
		Op = AnyValue,
		MustExist = Check.Optional(Check.Boolean),
		Slot = Slot,
	}
end

local TxLegRules = LegRulesWith(LeftOut(NoSlot))
local TakeLegRules = LegRulesWith(LeftOut(NoSlotUnlessSerial))
local SerialLegRules = LegRulesWith(Check.Optional(SlotPathRule))

local function SlotOf(Value: unknown): { PathStep }?
	if Value == nil then
		return nil
	end
	assert(type(Value) == "table" and getmetatable(Value) == nil, CheckAccepted)
	local Checked = Value :: { unknown }
	local Steps: { PathStep } = {}
	for Index = 1, #Checked do
		local Step = Checked[Index]
		assert(type(Step) == "string" or type(Step) == "number", CheckAccepted)
		table.insert(Steps, Step)
	end
	return Steps
end

local function LegOf(Given: LegGiven, Slot: { PathStep }?, Where: string): CheckedLeg
	local Settings = Stores.SettingsOf(Given.Store)
	assert(Settings ~= nil, CheckAccepted)
	local Key = Keys.Key(Settings, Given.Key, Where)
	local OpKind, OpTerms = Args.Op(Settings, Given.Op, Where)
	return {
		Leg = { Key = Key, OpKind = OpKind, Terms = OpTerms, MustExist = Given.MustExist, Slot = Slot },
		Settings = Settings,
		Setup = Runner.OpenedSetup(Settings.Name),
	}
end

local function TxLegOf(Value: unknown, Where: string): CheckedLeg
	Check.Table({ [LegOption] = Value }, { [LegOption] = NoMetatable }, Where)
	local Given = Validated(Value, TxLegRules, Where) :: LegGiven
	return LegOf(Given, nil, Where)
end

local function TakeLeg(Value: unknown, Declaration: QuantityDeclaration, Where: string): CheckedLeg
	Check.Table({ [LegOption] = Value }, { [LegOption] = NoMetatable }, Where)
	local Shape = if Declaration.Serials == nil then TakeLegRules else SerialLegRules
	local Given = Validated(Value, Shape, Where) :: LegGiven
	local Checked = LegOf(Given, SlotOf(Given.Slot), Where)
	if Requests.ClassifyLeg(Checked.Leg, Checked.Setup).Kind == "Delta" then
		Check.Table({ Slot = Given.Slot }, { Slot = LeftOut(NoSlotOnDelta) }, Where)
	end
	return Checked
end

return {
	MadeStore = MadeStore,
	TxLegOf = TxLegOf,
	TakeLeg = TakeLeg,
}
