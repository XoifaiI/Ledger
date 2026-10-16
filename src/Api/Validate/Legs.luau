--!strict
--!optimize 2

--[=[
	Legs: a Tx's legs and name, judged before sending (transaction sheet 7 step 1, A11); the decider is the core's
	choice. The list is read once, as a raw copy; each leg is Leg's. Sizes are measured once amounts are checked, Encode
	marked as Stepping. Moves, takes and confirms reuse these checks, a part at its widest key and name.

	Return type: A plain table with Check, DeciderOf, CheckMove, PartLegsMost, TakeLegs, ConfirmLegs and NoLegs, and
	the CheckedTx and CheckedLegs types.
	Example usage:
		local Checked = Legs.Check(Given, Options, "Ledger.Tx")
--]=]

local Args = require("./Args")
local Check = require("../../Encoding/Check")
local Entries = require("../../Stored/Entries")
local HotShapes = require("../../Hot/Shapes")
local Leg = require("./Leg")
local Measure = require("../../Tx/Call/Measure")
local Names = require("../../Encoding/Names")
local Record = require("../../Constants/Record")
local Requests = require("../../Tx/Call/Requests")
local Rules = require("./Rules")
local ShellSetup = require("../../Shell/Setup")
local Stepping = require("../../Shell/Stepping")
local Terms = require("../../Tx/Call/Terms")
local Transaction = require("../../Constants/Transaction")
local TxShapes = require("../../Tx/Shapes")

type CheckedLeg = Leg.CheckedLeg
type GivenName = Names.GivenName
type KeysMode = ShellSetup.KeysMode
type LegForm = TxShapes.LegForm
type OpName = Names.OpName
type QuantityDeclaration = HotShapes.QuantityDeclaration
type Rule = Check.Rule
type Settings = ShellSetup.Settings
type TxLeg = TxShapes.TxLeg

type TxGiven = { Id: unknown, IdAt: unknown }

type Placed = {
	read Where: string,
	read Option: string,
}

type Places = {
	read Kind: Placed,
	read Pinned: Placed,
	read Marks: { Placed },
	read Ops: { Placed },
}

export type CheckedLegs = {
	read Legs: { TxLeg },
	read KeysByStore: { [string]: KeysMode },
}

export type CheckedTx = {
	read Legs: { TxLeg },
	read Name: GivenName?,
	read KeysByStore: { [string]: KeysMode },
}

local AnyValue = Check.AnyValue
local NoFields = Rules.NoFields
local OpWhere = Rules.OpWhere
local OrDefault = Rules.OrDefault
local Validated = Rules.Validated

local WindowSigmas = Transaction.WindowSigmasBelowOrphanAge

local PartLegAt = 1
local PartLegCount = 1
local TakePartOption = "Count"
local ConfirmPartOption = "Hold"

local CheckAccepted = "Legs: a Check rule accepted a value of another type. The rule must reject it"
local NoLegList: { TxLeg } = {}
local NoKeysByStore: { [string]: KeysMode } = {}
local NoLegs: CheckedLegs = { Legs = table.freeze(NoLegList), KeysByStore = table.freeze(NoKeysByStore) }
table.freeze(NoLegs)

local PartLegsAtLeastWanted = "at least 1 leg, or nil for no legs"
local NoEarlierKey = "a key that no earlier leg names"
local MarkBytesWanted = `at most {Record.MarkMax} bytes`
local OpBytesWanted = `at most {Transaction.OpMax} bytes as canonical JSON`

local function LegsAtLeastWanted(Least: number): string
	return `at least {Least} legs`
end

local function LegsAtMostWanted(Most: number): string
	return `at most {Most} legs, the lowest LegLimit of the legs' stores`
end

local function PartLegsAtMostWanted(Most: number): string
	local Counted = if Most == 1 then "1 leg" else `{Most} legs`
	return `at most {Counted}, one less than the lowest LegLimit of the quantity's store and the legs' stores`
end

local function WindowWanted(Limit: number, Store: string): string
	return `a kind whose window is below OrphanAge less {WindowSigmas} * Sigma of every leg's store, since this `
		.. `leg decides, and that is {Limit} in the store "{Store}"`
end

local function AtMost(Most: number, Wanted: string): Rule
	return function(Value: unknown): string?
		if type(Value) == "number" and Value <= Most then
			return nil
		end
		return Wanted
	end
end

local function AtLeast(Least: number, Wanted: string): Rule
	return function(Value: unknown): string?
		if type(Value) == "number" and Value >= Least then
			return nil
		end
		return Wanted
	end
end

local TxRules: { [string]: Rule } = {
	Id = AnyValue,
	IdAt = AnyValue,
}

local MarkFits = AtMost(Record.MarkMax, MarkBytesWanted)
local OpFits = AtMost(Transaction.OpMax, OpBytesWanted)
local EnoughLegs = AtLeast(Transaction.LegLeast, LegsAtLeastWanted(Transaction.LegLeast))
local EnoughPartLegs = AtLeast(1, PartLegsAtLeastWanted)
local LegsList = Rules.Plain(Check.List(AnyValue))

local function LegWhere(Where: string, Index: number): string
	return `{Where} Legs[{Index}]`
end

local function PinnedWhere(Where: string): string
	return `{Where} Legs`
end

local function LegList(Given: unknown, Enough: Rule, Where: string): { unknown }
	Check.Table({ Legs = Given }, { Legs = LegsList }, Where)
	assert(type(Given) == "table", CheckAccepted)
	local List = table.clone(Given :: { unknown })
	Check.Table({ Legs = #List }, { Legs = Enough }, Where)
	return List
end

local function LowestLegLimit(Checked: { CheckedLeg }): number?
	local Lowest: number? = nil
	for _, Each in Checked do
		local Limit = Each.Settings.LegLimit
		if Limit ~= nil and (Lowest == nil or Limit < Lowest) then
			Lowest = Limit
		end
	end
	return Lowest
end

local function WithinLegLimit(Checked: { CheckedLeg }, Where: string): ()
	local Lowest = LowestLegLimit(Checked)
	if Lowest == nil then
		return
	end
	Check.Table({ Legs = #Checked }, { Legs = AtMost(Lowest, LegsAtMostWanted(Lowest)) }, Where)
end

local function WithinPartLegLimit(WithPart: { CheckedLeg }, Where: string): ()
	local Lowest = LowestLegLimit(WithPart)
	if Lowest == nil then
		return
	end
	local Most = Lowest - PartLegCount
	Check.Table({ Legs = #WithPart - PartLegCount }, { Legs = AtMost(Most, PartLegsAtMostWanted(Most)) }, Where)
end

local function NotNamedIn(Named: { [string]: true }): Rule
	return function(Value: unknown): string?
		if type(Value) == "string" and Named[Value] then
			return NoEarlierKey
		end
		return nil
	end
end

local function DistinctKeys(Checked: { CheckedLeg }, Where: string): ()
	local NamedByStore: { [string]: { [string]: true } } = {}
	for Index, Each in Checked do
		local Key = Each.Leg.Key
		local Named = NamedByStore[Key.Store] or {}
		NamedByStore[Key.Store] = Named
		Check.Table({ Key = Key.Key }, { Key = NotNamedIn(Named) }, LegWhere(Where, Index))
		Named[Key.Key] = true
	end
end

local function NameOf(Options: unknown, Where: string): GivenName?
	local Given = Validated(OrDefault(Options, NoFields), TxRules, Where) :: TxGiven
	return Args.GameName(Args.InOptions, Given.Id, Given.IdAt, Where)
end

local function DeciderIndexOf(Checked: { CheckedLeg }): number
	local Forms: { LegForm } = {}
	for _, Each in Checked do
		table.insert(Forms, Requests.ClassifyLeg(Each.Leg, Each.Setup))
	end
	return Terms.ChooseDecider(Forms, nil)
end

local function WindowBelow(Windows: { [string]: number }, Settings: Settings): Rule
	local Wanted = WindowWanted(Rules.WindowBoundOf(Settings), Settings.Name)
	return function(Value: unknown): string?
		if type(Value) == "string" and Rules.IsBelowWindowBound(Entries.WindowOf(Windows, Value), Settings) then
			return nil
		end
		return Wanted
	end
end

local function CheckAt(At: Placed, Value: unknown, Item: Rule): ()
	Check.Table({ [At.Option] = Value }, { [At.Option] = Item }, At.Where)
end

local function TxPlaces(Count: number, DeciderIndex: number, Where: string): Places
	local Marks: { Placed } = {}
	local Ops: { Placed } = {}
	for Index = 1, Count do
		table.insert(Marks, { Where = LegWhere(Where, Index), Option = "Mark" })
		table.insert(Ops, { Where = LegWhere(Where, Index), Option = "Op" })
	end
	return {
		Kind = { Where = OpWhere(LegWhere(Where, DeciderIndex)), Option = "Kind" },
		Pinned = { Where = PinnedWhere(Where), Option = "PinnedRecord" },
		Marks = Marks,
		Ops = Ops,
	}
end

local function MovePlaces(Options: { string }, DeciderIndex: number, Where: string): Places
	local Each: { Placed } = {}
	for _, Option in Options do
		table.insert(Each, { Where = Where, Option = Option })
	end
	return { Kind = Each[DeciderIndex], Pinned = Each[DeciderIndex], Marks = Each, Ops = Each }
end

local function PartStepPlaces(LegCount: number, PartOption: string, Where: string): Places
	local Part: Placed = { Where = Where, Option = PartOption }
	local Marks: { Placed } = { Part }
	local Ops: { Placed } = { { Where = Where, Option = "Price" } }
	for Index = 1, LegCount do
		table.insert(Marks, { Where = LegWhere(Where, Index), Option = "Mark" })
		table.insert(Ops, { Where = LegWhere(Where, Index), Option = "Op" })
	end
	return { Kind = Part, Pinned = { Where = PinnedWhere(Where), Option = "PinnedRecord" }, Marks = Marks, Ops = Ops }
end

local function Window(Checked: { CheckedLeg }, DeciderIndex: number, At: Placed): ()
	local Deciding = Checked[DeciderIndex]
	local Windows = Deciding.Setup.Limits.TimedWindows
	for _, Each in Checked do
		CheckAt(At, Deciding.Leg.OpKind, WindowBelow(Windows, Each.Settings))
	end
end

local function MeasuredNameOf(Name: GivenName?): OpName
	if Name == nil then
		return Measure.WidestDrawnName
	end
	return Measure.MeasuredName(Name)
end

local function Sizes(Checked: { CheckedLeg }, Legs: { TxLeg }, DeciderIndex: number, Measured: OpName, At: Places): ()
	local Pinned = Measure.PinnedRecordBytes(Legs, DeciderIndex, Checked[DeciderIndex].Setup, Measured)
	CheckAt(At.Pinned, Pinned, MarkFits)

	local DeciderKey = Legs[DeciderIndex].Key
	for Index, Each in Checked do
		if Index == DeciderIndex then
			continue
		end
		local Bytes = Stepping.Run(Measure.MarkBytes, Each.Leg, Each.Setup, DeciderKey, Measured)
		CheckAt(At.Marks[Index], Bytes, MarkFits)
	end

	for Index, Each in Checked do
		CheckAt(At.Ops[Index], Measure.OpBytes(Each.Leg.Terms), OpFits)
	end
end

local function LegsOf(Checked: { CheckedLeg }): { TxLeg }
	local Legs: { TxLeg } = {}
	for _, Each in Checked do
		table.insert(Legs, Each.Leg)
	end
	return Legs
end

local function KeysByStoreOf(Checked: { CheckedLeg }): { [string]: KeysMode }
	local KeysByStore: { [string]: KeysMode } = {}
	for _, Each in Checked do
		KeysByStore[Each.Settings.Name] = Each.Settings.Keys
	end
	return KeysByStore
end

local function CheckMove(
	Checked: { CheckedLeg },
	DeciderIndex: number,
	Name: GivenName?,
	Options: { string },
	Where: string
): ()
	local At = MovePlaces(Options, DeciderIndex, Where)
	Window(Checked, DeciderIndex, At.Kind)
	Sizes(Checked, LegsOf(Checked), DeciderIndex, MeasuredNameOf(Name), At)
end

local function PinnedBytesWith(Part: CheckedLeg, Receiver: CheckedLeg, Count: number, Name: OpName): number
	local Legs: { TxLeg } = table.create(Count, Part.Leg)
	table.insert(Legs, Receiver.Leg)
	return Measure.PinnedRecordBytes(Legs, Count + 1, Receiver.Setup, Name)
end

local function PartLegsMost(Part: CheckedLeg, Receiver: CheckedLeg, Parts: number, Name: GivenName?): number
	local Measured = MeasuredNameOf(Name)
	local Most = Parts
	local Lowest = LowestLegLimit({ Part, Receiver })
	if Lowest ~= nil then
		Most = math.min(Most, Lowest - 1)
	end
	local Fitting = 1
	for Count = 2, Most do
		if PinnedBytesWith(Part, Receiver, Count, Measured) > Record.MarkMax then
			break
		end
		Fitting = Count
	end
	return Fitting
end

local function PartStepLegs(
	Part: CheckedLeg,
	Given: unknown,
	Declaration: QuantityDeclaration,
	Measured: OpName,
	PartOption: string,
	Where: string
): CheckedLegs
	local Checked: { CheckedLeg } = {}
	for Index, Value in LegList(Given, EnoughPartLegs, Where) do
		table.insert(Checked, Leg.TakeLeg(Value, Declaration, LegWhere(Where, Index)))
	end
	local WithPart: { CheckedLeg } = table.clone(Checked)
	table.insert(WithPart, PartLegAt, Part)
	WithinPartLegLimit(WithPart, Where)
	DistinctKeys(Checked, Where)

	local At = PartStepPlaces(#Checked, PartOption, Where)
	Window(WithPart, PartLegAt, At.Kind)
	Sizes(WithPart, LegsOf(WithPart), PartLegAt, Measured, At)
	return { Legs = LegsOf(Checked), KeysByStore = KeysByStoreOf(Checked) }
end

local function TakeLegs(
	Part: CheckedLeg,
	Given: unknown,
	Declaration: QuantityDeclaration,
	Name: GivenName?,
	Where: string
): CheckedLegs
	local Measured = Names.WithPart(MeasuredNameOf(Name), Declaration.Parts - 1)
	return PartStepLegs(Part, Given, Declaration, Measured, TakePartOption, Where)
end

local function ConfirmLegs(
	Part: CheckedLeg,
	Given: unknown,
	Declaration: QuantityDeclaration,
	Where: string
): CheckedLegs
	return PartStepLegs(Part, Given, Declaration, Measure.WidestDrawnName, ConfirmPartOption, Where)
end

local function CheckTx(Given: unknown, Options: unknown, Where: string): CheckedTx
	local Checked: { CheckedLeg } = {}
	for Index, Value in LegList(Given, EnoughLegs, Where) do
		table.insert(Checked, Leg.TxLegOf(Value, LegWhere(Where, Index)))
	end
	WithinLegLimit(Checked, Where)
	DistinctKeys(Checked, Where)
	local Name = NameOf(Options, Where)
	local DeciderIndex = DeciderIndexOf(Checked)
	local At = TxPlaces(#Checked, DeciderIndex, Where)
	Window(Checked, DeciderIndex, At.Kind)

	local Legs = LegsOf(Checked)
	Sizes(Checked, Legs, DeciderIndex, MeasuredNameOf(Name), At)
	return { Legs = Legs, Name = Name, KeysByStore = KeysByStoreOf(Checked) }
end

return {
	Check = CheckTx,
	DeciderOf = DeciderIndexOf,
	CheckMove = CheckMove,
	PartLegsMost = PartLegsMost,
	TakeLegs = TakeLegs,
	ConfirmLegs = ConfirmLegs,
	NoLegs = NoLegs,
}
