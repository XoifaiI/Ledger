--!strict
--!optimize 2

--[=[
	Moves: a quantity's moves' arguments, Confirm, Release, Deposit, Withdraw and a gather (hot keys H8, A11). A hold
	handle must be one this quantity's Hold gave. Only an open quantity takes a Deposit or gathers; a final one moves
	only units between parts, and a serial one none (the owner). A Confirm's legs beside its hold's part are Legs'.

	Return type: A plain table with Gathering, HoldHandle, ConfirmOptions, Deposit and Withdraw, and the Deposit
	and Gathering types.
	Example usage:
		local Moved = Moves.Withdraw(Settings, Declaration, 5, 0, 1, "u", nil, "Quantity:Withdraw")
--]=]

local Balance = require("./Balance")
local Balances = require("../../Tx/Legs/Balances")
local Check = require("../../Encoding/Check")
local Handles = require("../Handles")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../../Hot/Shapes")
local KeyLegs = require("./KeyLegs")
local Leg = require("./Leg")
local Legs = require("./Legs")
local PartBuild = require("../../Hot/Part/Build")
local Quantity = require("./Quantity")
local Rules = require("./Rules")
local ShellSetup = require("../../Shell/Setup")
local TxShapes = require("../../Tx/Shapes")

type CheckedLeg = Leg.CheckedLeg
type CheckedLegs = Legs.CheckedLegs
type ConfirmTerms = HotShapes.ConfirmTerms
type CreditTerms = HotShapes.CreditTerms
type DepositTo = HotShapes.DepositTo
type HoldHandle = HotShapes.HoldHandle
type KeysMode = ShellSetup.KeysMode
type QuantityDeclaration = HotShapes.QuantityDeclaration
type Rule = Check.Rule
type Settings = ShellSetup.Settings
type TakeName = HotShapes.TakeName
type TxLeg = TxShapes.TxLeg
type WithdrawTo = HotShapes.WithdrawTo

type Prices = { [string]: unknown }

type DepositSource = { read Kind: "Minted" } | { read Kind: "Key", read Leg: TxLeg }

export type Deposit = {
	read To: DepositTo,
	read From: DepositSource,
	read KeysByStore: { [string]: KeysMode },
}

type Withdrawal = {
	read Part: number,
	read Field: string,
	read Amount: unknown,
	read To: WithdrawTo,
	read KeysByStore: { [string]: KeysMode },
}

export type Gathering = {
	read Receiver: TxLeg,
	read PartLegsMost: number,
	read Name: TakeName?,
	read KeysByStore: { [string]: KeysMode },
}

type GatherGiven = {
	Kind: unknown,
	Id: unknown,
	IdAt: unknown,
}

type WithdrawGiven = { Kind: unknown }

type ConfirmGiven = { Price: unknown, Legs: unknown }

type DepositGiven = {
	From: unknown,
	Field: unknown,
	Kind: unknown,
	Part: number?,
}

local AnyValue = Check.AnyValue
local OrDefault = Rules.OrDefault
local Validated = Rules.Validated

local Directions = Balances.Direction
local Modes = Hot.Mode
local FreeField = Hot.FreeField

local CreditLegAt = 2

local FromOption = "From"
local ToOption = "To"
local CountOption = "Count"

local CheckAccepted = "Moves: a Check rule accepted a value of another type. The rule must reject it"
local ProceedsNotDeclared = "Moves: a quantity's proceeds field is a balance field its store declares. "
	.. "Ledger.New checks it first"
local DepositWanted = `"{Modes.Open}", since a final quantity's stock is exactly its declared Stock`
local GatherWanted = `"{Modes.Open}", since only an open quantity gathers`
local StockMoveWanted = `"{FreeField}", since a final quantity's parts move only units between them`
local StockStaysWanted = "a proceeds field, since a final quantity's units leave only by being sold or held"
local SerialNoMoveWanted = "a key, since a serial quantity's units never move between parts"
local HoldWanted = "a hold handle this quantity's Hold gave"
local OtherQuantityWanted = "a hold handle this quantity's Hold gave, not another quantity's"
local NoFieldWithoutFrom = "nil when no From is given"
local NoKindToPart = "nil when To is a part, since a part's credit has one kind"

local GatherRules: { [string]: Rule } = {
	Kind = AnyValue,
	Id = AnyValue,
	IdAt = AnyValue,
}

local WithdrawRules: { [string]: Rule } = {
	Kind = AnyValue,
}

local ConfirmRules: { [string]: Rule } = {
	Price = AnyValue,
	Legs = AnyValue,
}

local DepositRules: { [string]: Rule } = {
	From = AnyValue,
	Field = AnyValue,
	Kind = AnyValue,
	Part = AnyValue,
}

local DepositLegs = { "From", "Part" }
local WithdrawLegs = { "Part", "To" }
local GatherLegs = { "Count", "To" }

local function PartWanted(Parts: number): string
	return `a part of the quantity, a whole number from 0 to {Parts - 1}`
end

local function DestinationWanted(Parts: number): string
	return `another part of the quantity, a whole number from 0 to {Parts - 1}, or a key as a table of Store and Key`
end

local function PartIndex(Declaration: QuantityDeclaration): Rule
	local Wanted = PartWanted(Declaration.Parts)
	local Index = Check.Whole(0, Declaration.Parts - 1)
	return function(Value: unknown): string?
		if Index(Value) == nil then
			return nil
		end
		return Wanted
	end
end

local function Destination(Declaration: QuantityDeclaration, From: number): Rule
	local Wanted = DestinationWanted(Declaration.Parts)
	local Index = Check.Whole(0, Declaration.Parts - 1)
	return function(Value: unknown): string?
		if type(Value) == "table" then
			return nil
		end
		if Index(Value) == nil and Value ~= From then
			return nil
		end
		return Wanted
	end
end

local function HeldBy(Declaration: QuantityDeclaration): Rule
	return function(Value: unknown): string?
		local Made = Handles.HoldQuantityOf(Value)
		if Made == Declaration then
			return nil
		end
		if Made ~= nil then
			return OtherQuantityWanted
		end
		return HoldWanted
	end
end

local function NoSerialMove(Declaration: QuantityDeclaration): Rule
	return function(_Value: unknown): string?
		if Declaration.Serials == nil then
			return nil
		end
		return SerialNoMoveWanted
	end
end

local function NotUnits(Value: unknown): string?
	if Value == FreeField then
		return StockStaysWanted
	end
	return nil
end

local function OpenOnly(Declaration: QuantityDeclaration, Wanted: string, Where: string): ()
	Check.Table({ Mode = Declaration.Mode }, { Mode = Rules.Equals(Modes.Open, Wanted) }, Where)
end

local function CreditTermsOf(Settings: Settings, Declaration: QuantityDeclaration, Units: number): CreditTerms
	return { Fingerprint = Quantity.PartFingerprintOf(Settings, Declaration), Count = Units }
end

local function FieldAmount(Settings: Settings, Field: string, Amount: unknown, Where: string): ()
	if Field == FreeField then
		Quantity.Count(Amount, Where)
		return
	end
	local Arithmetic = ShellSetup.FieldArithmeticsOf(Settings)[Field]
	assert(Arithmetic ~= nil, ProceedsNotDeclared)
	Check.Table({ Count = Amount }, { Count = Balance.IsCallAmountOf(Arithmetic) }, Where)
end

local function KeysByStoreOf(Leg: CheckedLeg): { [string]: KeysMode }
	return { [Leg.Settings.Name] = Leg.Settings.Keys }
end

local function DepositToOf(Part: number?): DepositTo
	if Part == nil then
		return { Kind = "Home" }
	end
	return { Kind = "Part", Index = Part }
end

local function ToPart(
	Declaration: QuantityDeclaration,
	Field: string,
	To: number,
	Given: WithdrawGiven,
	Where: string
): WithdrawTo
	Check.Table({ Kind = Given.Kind }, { Kind = Rules.LeftOut(NoKindToPart) }, Where)
	Check.Table({ To = To }, { To = NoSerialMove(Declaration) }, Where)
	if Declaration.Mode == Modes.Final then
		Check.Table({ Field = Field }, { Field = Rules.Equals(FreeField, StockMoveWanted) }, Where)
	end
	return { Kind = "Part", Index = To }
end

local function ToKey(
	Settings: Settings,
	Debit: TxLeg,
	Field: string,
	To: unknown,
	Given: WithdrawGiven,
	Amount: unknown,
	Where: string
): CheckedLeg
	local Credit = KeyLegs.BalanceLeg(To, ToOption, Field, Given.Kind, Directions.Credit, Amount, Where)
	local Checked: { CheckedLeg } = { KeyLegs.CheckedOf(Debit, Settings), Credit }
	Legs.CheckMove(Checked, Legs.DeciderOf(Checked), nil, WithdrawLegs, Where)
	return Credit
end

local function Gathering(
	Settings: Settings,
	Declaration: QuantityDeclaration,
	Units: number,
	To: unknown,
	Field: unknown,
	Options: unknown,
	Where: string
): Gathering
	OpenOnly(Declaration, GatherWanted, Where)
	local Given = Validated(OrDefault(Options, Rules.NoFields), GatherRules, Where) :: GatherGiven
	local Name = Quantity.TakeName(Given.Id, Given.IdAt, Where)
	local Receiver = KeyLegs.BalanceLeg(To, ToOption, Field, Given.Kind, Directions.Credit, Units, Where)
	local Widest =
		PartBuild.DebitLeg(Quantity.PartPlaceOf(Settings, Declaration), Declaration.Parts - 1, FreeField, Units)
	local Part = KeyLegs.CheckedOf(Widest, Settings)
	local Checked: { CheckedLeg } = { Part, Receiver }
	Legs.CheckMove(Checked, Legs.DeciderOf(Checked), Name, GatherLegs, Where)
	local Most = Legs.PartLegsMost(Part, Receiver, Declaration.Parts, Name)
	return { Receiver = Receiver.Leg, PartLegsMost = Most, Name = Name, KeysByStore = KeysByStoreOf(Receiver) }
end

local function HoldHandle(Declaration: QuantityDeclaration, Value: unknown, Where: string): HoldHandle
	Check.Table({ Hold = Value }, { Hold = HeldBy(Declaration) }, Where)
	assert(type(Value) == "table", CheckAccepted)
	return Value :: HoldHandle
end

local function ConfirmLeg(
	Settings: Settings,
	Declaration: QuantityDeclaration,
	Hold: HoldHandle,
	Paid: Prices
): CheckedLeg
	local Fingerprint = Quantity.PartFingerprintOf(Settings, Declaration)
	local Terms: ConfirmTerms = { Fingerprint = Fingerprint, Id = Hold.Id, Count = Hold.Count, Price = Paid }
	local Place = Quantity.PartPlaceOf(Settings, Declaration)
	return KeyLegs.CheckedOf(PartBuild.PartLeg(Place, Hold.Part, Hot.PartOpKind.Confirm, Terms), Settings)
end

local function ConfirmOptions(
	Settings: Settings,
	Declaration: QuantityDeclaration,
	Hold: HoldHandle,
	Options: unknown,
	Where: string
): (Prices, CheckedLegs)
	local Given = Validated(OrDefault(Options, Rules.NoFields), ConfirmRules, Where) :: ConfirmGiven
	local Paid = Quantity.Price(Settings, Declaration, Given.Price, Where)
	if Given.Legs == nil then
		return Paid, Legs.NoLegs
	end
	local Part = ConfirmLeg(Settings, Declaration, Hold, Paid)
	return Paid, Legs.ConfirmLegs(Part, Given.Legs, Declaration, Where)
end

local function Deposit(
	Settings: Settings,
	Declaration: QuantityDeclaration,
	Units: number,
	Options: unknown,
	Where: string
): Deposit
	OpenOnly(Declaration, DepositWanted, Where)
	local Given = Validated(OrDefault(Options, Rules.NoFields), DepositRules, Where) :: DepositGiven
	local Part = Given.Part
	Check.Table({ Part = Part }, { Part = Check.Optional(PartIndex(Declaration)) }, Where)
	local To = DepositToOf(Part)
	if Given.From == nil then
		local NoFrom = Rules.LeftOut(NoFieldWithoutFrom)
		Check.Table({ Field = Given.Field, Kind = Given.Kind }, { Field = NoFrom, Kind = NoFrom }, Where)
		return { To = To, From = { Kind = "Minted" }, KeysByStore = {} }
	end
	local From = KeyLegs.BalanceLeg(Given.From, FromOption, Given.Field, Given.Kind, Directions.Debit, Units, Where)
	local Index = if To.Kind == "Part" then To.Index else Declaration.Parts - 1
	local Terms = CreditTermsOf(Settings, Declaration, Units)
	local Credit = PartBuild.CreditLeg(Quantity.PartPlaceOf(Settings, Declaration), Index, Terms)
	Legs.CheckMove({ From, KeyLegs.CheckedOf(Credit, Settings) }, CreditLegAt, nil, DepositLegs, Where)
	return { To = To, From = { Kind = "Key", Leg = From.Leg }, KeysByStore = KeysByStoreOf(From) }
end

local function Withdraw(
	Settings: Settings,
	Declaration: QuantityDeclaration,
	Count: unknown,
	Part: unknown,
	To: unknown,
	Field: unknown,
	Options: unknown,
	Where: string
): Withdrawal
	local Given = Validated(OrDefault(Options, Rules.NoFields), WithdrawRules, Where) :: WithdrawGiven
	Check.Table({ Part = Part }, { Part = PartIndex(Declaration) }, Where)
	assert(type(Part) == "number", CheckAccepted)
	Check.Table({ Field = Field }, { Field = Check.OneOf(FreeField, table.unpack(Declaration.Proceeds)) }, Where)
	assert(type(Field) == "string", CheckAccepted)
	Check.Table({ To = To }, { To = Destination(Declaration, Part) }, Where)
	local Amount = Rules.FrozenAmount(Count, CountOption, Where)
	if type(To) == "number" then
		local Moved = ToPart(Declaration, Field, To, Given, Where)
		Quantity.Count(Amount, Where)
		FieldAmount(Settings, Field, Amount, Where)
		return { Part = Part, Field = Field, Amount = Amount, To = Moved, KeysByStore = {} }
	end
	if Declaration.Mode == Modes.Final then
		Check.Table({ Field = Field }, { Field = NotUnits }, Where)
	end
	FieldAmount(Settings, Field, Amount, Where)
	local Debit = PartBuild.DebitLeg(Quantity.PartPlaceOf(Settings, Declaration), Part, Field, Amount)
	local Credit = ToKey(Settings, Debit, Field, To, Given, Amount, Where)
	return {
		Part = Part,
		Field = Field,
		Amount = Amount,
		To = { Kind = "Key", Credit = Credit.Leg },
		KeysByStore = KeysByStoreOf(Credit),
	}
end

return {
	Gathering = Gathering,
	HoldHandle = HoldHandle,
	ConfirmOptions = ConfirmOptions,
	Deposit = Deposit,
	Withdraw = Withdraw,
}
