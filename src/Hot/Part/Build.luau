--!strict
--!optimize 2

--[=[
	Build: a part's key, share, serial range and fp, the part build, a new part, the debit kind of a field and a
	call's writer ops and Txs (hot keys sheet H1, H2, H5). The build's reducer gives no state: the part's own rules
	judge its ops.

	Return type: A plain table of functions, and the PartRef type.
	Example usage:
		local Key = Build.PartKey("Shop", "global", Declaration, 0) --> { Key = "$P:sword:4:0", ... }
		Build.PartOfKey(Key) --> { Name = "sword", Parts = 4, Index = 0 }
--]=]

local Balances = require("../../Tx/Legs/Balances")
local Events = require("../../Events")
local HashInputs = require("../../Encoding/HashInputs")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../Shapes")
local Json = require("../../Encoding/Json")
local Names = require("../../Encoding/Names")
local Part = require("../../Stored/Items/Part")
local Record = require("../../Constants/Record")
local Shapes = require("../../Shapes")
local TxShapes = require("../../Tx/Shapes")

type Arithmetic = Balances.Arithmetic
type GivenName = Names.GivenName
type KeyReference = Names.KeyReference
type StoreKey = Names.StoreKey
type PartRecord = Part.PartRecord
type PlainPart = Part.PlainPart
type SerialPart = Part.SerialPart
type QuantityDeclaration = HotShapes.QuantityDeclaration
type QuantityName = HotShapes.QuantityName
type Serials = HotShapes.Serials
type CreditTerms = HotShapes.CreditTerms
type TxCall = Events.TxCall
type TxLeg = TxShapes.TxLeg
type Build = Shapes.Build
type WaitingForm = Shapes.WaitingForm
type WaitingOp = Shapes.WaitingOp

type Fields = { [unknown]: unknown }

export type PartPlace = {
	read Store: string,
	read Scope: string,
	read Quantity: QuantityName,
}

export type PartRef = {
	read Name: string,
	read Parts: number,
	read Index: number,
}

local KeyKinds = Record.KeyKind
local PartKeyPrefix = Record.PartKeyPrefix

local FreeField = Hot.FreeField
local PartRecordKey = Hot.PartRecordKey
local FinalMode = Hot.Mode.Final

local DefaultArithmetic = Balances.DefaultArithmetic
local DebitDirection = Balances.Direction.Debit

local PartLegAt = 1

local NoUnits = 0

local DebitKindPrefix = Hot.DebitKindPrefix

local ModuleName = "Build"
local PartKeyShape = "^(.*):(%d+):(%d+)$"
local NotAPartKey = `{ModuleName}: this key does not name a part of a quantity. The caller must give a part's key`

local function ScaledDown(Whole: number, Parts: number, Index: number): number
	return (Whole // Parts) * Index + (Whole % Parts) * Index // Parts
end

local function DebitKindOf(Field: string): string
	return DebitKindPrefix .. Field
end

local function IsFinalDeclaration(Declaration: QuantityDeclaration): boolean
	return Declaration.Mode == FinalMode
end

local function NewPlainRecord(Fingerprint: number, OpenedAt: number, IsFinal: boolean): PlainPart
	return {
		Fingerprint = Fingerprint,
		IsSealed = false,
		IsClosed = false,
		IsFinal = IsFinal,
		IsSerial = false,
		OpenedAt = OpenedAt,
		Sold = 0,
		Carried = {},
		Holds = {},
	}
end

local function NewSerialRecord(Fingerprint: number, OpenedAt: number, IsFinal: boolean, Range: Serials): SerialPart
	return {
		Fingerprint = Fingerprint,
		IsSealed = false,
		IsClosed = false,
		IsFinal = IsFinal,
		IsSerial = true,
		OpenedAt = OpenedAt,
		Sold = 0,
		Carried = {},
		SerialNext = Range.First,
		SerialEnd = Range.First + Range.Count,
		Holds = {},
		Returned = {},
	}
end

local function NewRecord(Terms: HotShapes.OpenTerms): PartRecord
	if Terms.Range == nil then
		return NewPlainRecord(Terms.Fingerprint, Terms.OpenedAt, Terms.IsFinal)
	end
	return NewSerialRecord(Terms.Fingerprint, Terms.OpenedAt, Terms.IsFinal, Terms.Range)
end

local function NewEmptyRecord(): PlainPart
	local Empty: PlainPart = {
		IsSealed = false,
		IsClosed = false,
		IsFinal = false,
		IsSerial = false,
		Sold = 0,
		Carried = {},
		Holds = {},
	}
	table.freeze(Empty.Carried)
	table.freeze(Empty.Holds)
	return table.freeze(Empty)
end

local function NewEmptyState(): { [string]: unknown }
	local Empty: { [string]: unknown } = { [FreeField] = NoUnits, [PartRecordKey] = NewEmptyRecord() }
	return table.freeze(Empty)
end

local function NotAPartOp(State: unknown, Terms: unknown): Fields?
	return nil
end

local function PartKey(Store: string, Scope: string, Declaration: QuantityName, Index: number): StoreKey
	return { Store = Store, Scope = Scope, Key = `{PartKeyPrefix}{Declaration.Name}:{Declaration.Parts}:{Index}` }
end

local function PartOfKey(Key: StoreKey): PartRef
	local Name, Parts, Index = string.match(string.sub(Key.Key, #PartKeyPrefix + 1), PartKeyShape)
	local PartCount = tonumber(Parts)
	local PartIndex = tonumber(Index)
	if Name == nil or PartCount == nil or PartIndex == nil then
		error(NotAPartKey)
	end
	return { Name = Name, Parts = PartCount, Index = PartIndex }
end

local function ShareOf(Declaration: QuantityDeclaration, Index: number): number
	local Stock = Declaration.Stock
	if Stock == nil then
		return 0
	end
	local Parts = Declaration.Parts
	return ScaledDown(Stock, Parts, Index + 1) - ScaledDown(Stock, Parts, Index)
end

local function RangeOf(Declaration: QuantityDeclaration, Index: number): Serials?
	local Serials = Declaration.Serials
	if Serials == nil then
		return nil
	end
	local Parts = Declaration.Parts
	local First = Serials.First + ScaledDown(Serials.Count, Parts, Index)
	local End = Serials.First + ScaledDown(Serials.Count, Parts, Index + 1)
	return { First = First, Count = End - First }
end

local function FingerprintOf(Encoding: HashInputs.Encoding, Declaration: QuantityDeclaration): number
	local Input = HashInputs.DeclarationInput(
		Declaration.Name,
		Declaration.Parts,
		IsFinalDeclaration(Declaration),
		Declaration.Stock,
		Declaration.Serials,
		Declaration.Proceeds
	)
	return HashInputs.DeclarationFingerprint(HashInputs.Hash(Encoding, Input))
end

local function NewBuild(
	StoreBalances: { [string]: Arithmetic },
	MayReference: ((Reference: KeyReference) -> boolean)?
): Build
	local PartBalances = table.clone(StoreBalances)
	PartBalances[FreeField] = DefaultArithmetic
	local Declared: { [string]: boolean } = {}
	local BalanceOps: { [string]: Balances.Declaration } = {}
	for Field, Arithmetic in PartBalances do
		Declared[Field] = true
		BalanceOps[DebitKindOf(Field)] =
			table.freeze({ Field = Field, Direction = DebitDirection, Arithmetic = Arithmetic })
	end
	local Made: Build = {
		KeyKind = KeyKinds.Part,
		Migrations = {},
		MigrationCount = 0,
		BreakingIndex = 0,
		Reducer = NotAPartOp,
		Default = NewEmptyState(),
		Declared = Declared,
		Balances = PartBalances,
		BalanceOps = BalanceOps,
		MayReference = MayReference,
	}
	table.freeze(Made.Migrations)
	table.freeze(Made.Declared)
	table.freeze(Made.Balances)
	table.freeze(Made.BalanceOps)
	return table.freeze(Made)
end

local function OpenTerms(
	Declaration: QuantityDeclaration,
	Index: number,
	OpenedAt: number,
	Fingerprint: number
): HotShapes.OpenTerms
	return {
		Fingerprint = Fingerprint,
		OpenedAt = OpenedAt,
		IsFinal = IsFinalDeclaration(Declaration),
		Free = ShareOf(Declaration, Index),
		Range = RangeOf(Declaration, Index),
	}
end

local function NewPart(Terms: HotShapes.OpenTerms): Fields
	return { [FreeField] = Terms.Free, [PartRecordKey] = NewRecord(Terms) }
end

local function NewWaitingOp(
	Form: WaitingForm,
	OpKind: string,
	Terms: unknown,
	CallId: number,
	JoinedAt: number,
	IsStep: boolean
): WaitingOp
	return {
		Form = Form,
		OpKind = OpKind,
		Terms = Terms,
		JoinedAt = JoinedAt,
		MustExist = true,
		Size = Json.Size(Terms),
		CallId = CallId,
		IsStep = IsStep,
	}
end

local function NewCallOp(Form: WaitingForm, OpKind: string, Terms: unknown, CallId: number, JoinedAt: number): WaitingOp
	return NewWaitingOp(Form, OpKind, Terms, CallId, JoinedAt, false)
end

local function NewStepOp(Form: WaitingForm, OpKind: string, Terms: unknown, CallId: number, JoinedAt: number): WaitingOp
	return NewWaitingOp(Form, OpKind, Terms, CallId, JoinedAt, true)
end

local function TxOf(CallId: number, Legs: { TxLeg }, DeciderAt: number): TxCall
	return { Kind = "Call", Method = "Tx" :: "Tx", CallId = CallId, Legs = Legs, Hot = DeciderAt, Name = nil }
end

local function RuledTxOf(CallId: number, Legs: { TxLeg }): TxCall
	return { Kind = "Call", Method = "Tx" :: "Tx", CallId = CallId, Legs = Legs, Hot = nil, Name = nil }
end

local function NamedTxOf(CallId: number, Legs: { TxLeg }, Name: GivenName): TxCall
	return { Kind = "Call", Method = "Tx" :: "Tx", CallId = CallId, Legs = Legs, Hot = nil, Name = Name }
end

local function PartTx(CallId: number, First: TxLeg, OtherLegs: { TxLeg }): TxCall
	local Legs: { TxLeg } = { First }
	table.move(OtherLegs, 1, #OtherLegs, PartLegAt + 1, Legs)
	return TxOf(CallId, Legs, PartLegAt)
end

local function PartLeg(Where: PartPlace, Index: number, OpKind: string, Terms: unknown): TxLeg
	return {
		Key = PartKey(Where.Store, Where.Scope, Where.Quantity, Index),
		OpKind = OpKind,
		Terms = Terms,
		MustExist = true,
		Slot = nil,
	}
end

local function CreditLeg(Where: PartPlace, Index: number, Terms: CreditTerms): TxLeg
	return PartLeg(Where, Index, Hot.PartOpKind.Credit, Terms)
end

local function DebitLeg(Where: PartPlace, Index: number, Field: string, Amount: unknown): TxLeg
	return PartLeg(Where, Index, DebitKindOf(Field), { Amount = Amount })
end

return {
	PartKey = PartKey,
	PartOfKey = PartOfKey,
	FingerprintOf = FingerprintOf,
	NewBuild = NewBuild,
	OpenTerms = OpenTerms,
	NewPart = NewPart,
	NewCallOp = NewCallOp,
	NewStepOp = NewStepOp,
	TxOf = TxOf,
	RuledTxOf = RuledTxOf,
	NamedTxOf = NamedTxOf,
	PartTx = PartTx,
	PartLeg = PartLeg,
	CreditLeg = CreditLeg,
	DebitLeg = DebitLeg,
}
