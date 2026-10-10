--!strict
--!optimize 2
--!native

--[=[
	HashInputs: the numbers taken from a SHA-256 digest (spec/protocols/record/Format.md 4) and the builders
	of every hash input.

	The core may not call EncodingService, so SHA-256 comes in as an Encoding. Every field is self
	delimiting, never joined by a separator. Canonical JSON and an arithmetic's Encode text come already
	written by their owners.

	Return type: A plain table of functions, and the Encoding and input types.
	Example usage:
		local Input = HashInputs.CounterInput("abc")
		Format.ToString(Input) --> "JDabc"
--]=]

local Format = require("./Format")
local Names = require("./Names")
local Record = require("../Constants/Record")
local Wide = require("./Wide")

type Writer = Format.Writer
type Name = Names.Name

export type Encoding = {
	Sha256: (Input: buffer) -> buffer,
}

export type TxLegInput = {
	Store: string,
	Scope: string,
	Key: string,
	OpKind: string,
	MustExist: boolean?,
	PathCj: string?,
	BodyText: string,
}

export type TakePriceInput = {
	Field: string,
	AmountText: string,
}

export type SerialRunInput = {
	First: number,
	Count: number,
}

local NewWriter = Format.NewWriter
local ToBuffer = Format.ToBuffer
local ToString = Format.ToString
local WriteRaw = Format.WriteRaw
local WriteVarint = Format.WriteVarint
local WriteSignedNumber = Wide.WriteSignedNumber
local WriteFixedNumber = Format.WriteFixedNumber
local WriteName = Names.WriteName

local HashPrefixBits = 48
local FingerprintBits = 18
local DeclarationBits = 16
local BitsPerWord = 32

local HashDomain = table.freeze({
	OneKeyOp = "O",
	Bump = "B",
	Tx = "X",
	Cut = "C",
	Take = "K",
	Declaration = "Q",
	HomeShard = "S",
	BumpShard = "s",
	HomePart = "H",
	Walk = "W",
	Map = "M",
	ItemTag = "A",
	Counter = "J",
	Shown = "N",
	Touch = "L",
})

local HashFlag = table.freeze({
	None = "N",
	Some = "Y",
	MustExist = "T",
	MayBeMissing = "F",
	Erase = "E",
	Reset = "R",
	Final = "F",
	Open = "O",
})

local HashPrefixBytes = HashPrefixBits // Record.BitsPerByte
local ByteBase = 2 ^ Record.BitsPerByte
local FingerprintShift = 2 ^ (HashPrefixBits - FingerprintBits)
local DeclarationShift = 2 ^ (HashPrefixBits - DeclarationBits)

local InputCapacity = 64

local function ChoiceNumber(Digest: buffer): number
	local Value = 0
	for Index = 0, HashPrefixBytes - 1 do
		Value = Value * ByteBase + buffer.readu8(Digest, Index)
	end
	return Value
end

local function NameFingerprint(Digest: buffer): number
	return ChoiceNumber(Digest) // FingerprintShift
end

local function DeclarationFingerprint(Digest: buffer): number
	return ChoiceNumber(Digest) // DeclarationShift
end

local function TouchLevel(Digest: buffer): number
	return bit32.countlz(DeclarationFingerprint(Digest)) - (BitsPerWord - DeclarationBits)
end

local function Hash(Encoding: Encoding, Input: Writer): buffer
	return Encoding.Sha256(ToBuffer(Input))
end

local function WriteFingerprint(Out: Writer, Digest: buffer)
	WriteFixedNumber(Out, NameFingerprint(Digest))
end

local function WriteDeclarationFingerprint(Out: Writer, Digest: buffer)
	WriteFixedNumber(Out, DeclarationFingerprint(Digest))
end

local function StartInput(Domain: string): Writer
	local Out = NewWriter(InputCapacity)
	WriteRaw(Out, Domain)
	return Out
end

local function WriteHashString(Out: Writer, Text: string)
	WriteVarint(Out, #Text)
	WriteRaw(Out, Text)
end

local function WriteIsPresent(Out: Writer, IsPresent: boolean)
	if IsPresent then
		WriteRaw(Out, HashFlag.Some)
	else
		WriteRaw(Out, HashFlag.None)
	end
end

local function WriteEither(Out: Writer, Condition: boolean, IfTrue: string, IfFalse: string)
	if Condition then
		WriteRaw(Out, IfTrue)
	else
		WriteRaw(Out, IfFalse)
	end
end

local function OneKeyOpInput(OpKind: string, BodyCj: string): Writer
	local Out = StartInput(HashDomain.OneKeyOp)
	WriteHashString(Out, OpKind)
	WriteHashString(Out, BodyCj)
	return Out
end

local function BumpInput(Total: string, Shards: number, Amount: number): Writer
	local Out = StartInput(HashDomain.Bump)
	WriteHashString(Out, Total)
	WriteVarint(Out, Shards)
	WriteSignedNumber(Out, Amount)
	return Out
end

local function WriteLeg(Out: Writer, Leg: TxLegInput)
	WriteHashString(Out, Leg.Store)
	WriteHashString(Out, Leg.Scope)
	WriteHashString(Out, Leg.Key)
	WriteHashString(Out, Leg.OpKind)
	if Leg.MustExist == nil then
		WriteRaw(Out, HashFlag.None)
	else
		WriteEither(Out, Leg.MustExist, HashFlag.MustExist, HashFlag.MayBeMissing)
	end
	WriteIsPresent(Out, Leg.PathCj ~= nil)
	if Leg.PathCj ~= nil then
		WriteHashString(Out, Leg.PathCj)
	end
	WriteHashString(Out, Leg.BodyText)
end

local function TxInput(Legs: { TxLegInput }, DeciderIndex: number): Writer
	local Out = StartInput(HashDomain.Tx)
	WriteVarint(Out, #Legs)
	for _, Leg in Legs do
		WriteLeg(Out, Leg)
	end
	WriteVarint(Out, DeciderIndex)
	return Out
end

local function CutInput(IsErase: boolean, GivenStateCj: string?): Writer
	local Out = StartInput(HashDomain.Cut)
	WriteEither(Out, IsErase, HashFlag.Erase, HashFlag.Reset)
	WriteIsPresent(Out, GivenStateCj ~= nil)
	if GivenStateCj ~= nil then
		WriteHashString(Out, GivenStateCj)
	end
	return Out
end

local function TakeInput(Quantity: string, Parts: number, Count: number, Prices: { TakePriceInput }): Writer
	local Out = StartInput(HashDomain.Take)
	WriteHashString(Out, Quantity)
	WriteVarint(Out, Parts)
	WriteVarint(Out, Count)
	WriteVarint(Out, #Prices)
	for _, Price in Prices do
		WriteHashString(Out, Price.Field)
		WriteHashString(Out, Price.AmountText)
	end
	return Out
end

local function DeclarationInput(
	Quantity: string,
	Parts: number,
	IsFinal: boolean,
	Stock: number?,
	Serials: SerialRunInput?,
	Proceeds: { string }
): Writer
	local Out = StartInput(HashDomain.Declaration)
	WriteHashString(Out, Quantity)
	WriteVarint(Out, Parts)
	WriteEither(Out, IsFinal, HashFlag.Final, HashFlag.Open)
	WriteIsPresent(Out, Stock ~= nil)
	if Stock ~= nil then
		WriteVarint(Out, Stock)
	end
	WriteIsPresent(Out, Serials ~= nil)
	if Serials ~= nil then
		WriteVarint(Out, Serials.First)
		WriteVarint(Out, Serials.Count)
	end
	WriteVarint(Out, #Proceeds)
	for _, Field in Proceeds do
		WriteHashString(Out, Field)
	end
	return Out
end

local function HomeShardInput(Total: string, Shards: number, ServerNumber: number): Writer
	local Out = StartInput(HashDomain.HomeShard)
	WriteHashString(Out, Total)
	WriteVarint(Out, Shards)
	WriteVarint(Out, ServerNumber)
	return Out
end

local function BumpShardInput(Name: string): Writer
	local Out = StartInput(HashDomain.BumpShard)
	WriteHashString(Out, Name)
	return Out
end

local function HomePartInput(Quantity: string, Parts: number, ServerNumber: number): Writer
	local Out = StartInput(HashDomain.HomePart)
	WriteHashString(Out, Quantity)
	WriteVarint(Out, Parts)
	WriteVarint(Out, ServerNumber)
	return Out
end

local function WalkInput(Name: string): Writer
	local Out = StartInput(HashDomain.Walk)
	WriteHashString(Out, Name)
	return Out
end

local function MapInput(ItemKey: string): Writer
	local Out = StartInput(HashDomain.Map)
	WriteHashString(Out, ItemKey)
	return Out
end

local function ItemTagInput(Store: string, Scope: string): Writer
	local Out = StartInput(HashDomain.ItemTag)
	WriteHashString(Out, Store)
	WriteHashString(Out, Scope)
	return Out
end

local function CounterInput(JobId: string): Writer
	local Out = StartInput(HashDomain.Counter)
	WriteHashString(Out, JobId)
	return Out
end

local function ShownInput(Store: string, Scope: string, Key: string): Writer
	local Out = StartInput(HashDomain.Shown)
	WriteHashString(Out, Store)
	WriteHashString(Out, Scope)
	WriteHashString(Out, Key)
	return Out
end

local function TouchInput(ServerNumber: number, Name: Name): Writer
	local Field = NewWriter(InputCapacity)
	WriteName(Field, Name)
	local Out = StartInput(HashDomain.Touch)
	WriteVarint(Out, ServerNumber)
	WriteHashString(Out, ToString(Field))
	return Out
end

return {
	ChoiceNumber = ChoiceNumber,
	NameFingerprint = NameFingerprint,
	DeclarationFingerprint = DeclarationFingerprint,
	TouchLevel = TouchLevel,
	Hash = Hash,
	WriteFingerprint = WriteFingerprint,
	WriteDeclarationFingerprint = WriteDeclarationFingerprint,
	OneKeyOpInput = OneKeyOpInput,
	BumpInput = BumpInput,
	TxInput = TxInput,
	CutInput = CutInput,
	TakeInput = TakeInput,
	DeclarationInput = DeclarationInput,
	HomeShardInput = HomeShardInput,
	BumpShardInput = BumpShardInput,
	HomePartInput = HomePartInput,
	WalkInput = WalkInput,
	MapInput = MapInput,
	ItemTagInput = ItemTagInput,
	CounterInput = CounterInput,
	ShownInput = ShownInput,
	TouchInput = TouchInput,
}
