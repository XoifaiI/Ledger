--!strict
--!optimize 2

--[=[
	Part: a part's own state s (spec/protocols/record/Format.md 10) as text and as the state table. The free
	units u and the declared proceeds fields sit at the top, for balances and marks; the typed PartRecord sits
	under PartRecordKey. A proceeds field no declaration names is kept and written back. The empty part, with no
	fp or t_open, is never written.

	Return type: A plain table of functions, and the Hold, SerialHold, SerialRun, PartRecord and StoredPart types.
	Example usage:
		local State = Part.StateOfText("AAAA25h2AFAAA", {})
		State.u --> 5
--]=]

local Balances = require("../../Tx/Legs/Balances")
local Format = require("../../Encoding/Format")
local Hot = require("../../Constants/Hot")
local Losses = require("./Losses")
local Names = require("../../Encoding/Names")
local Record = require("../../Constants/Record")
local Timed = require("./Timed")
local Wide = require("../../Encoding/Wide")

type Writer = Format.Writer
type Reader = Format.Reader
type Name = Names.Name
type Arithmetic = Balances.Arithmetic
type FieldAmount = Losses.FieldAmount

type Fields = { [unknown]: unknown }

export type Hold = {
	Id: Name,
	Count: number,
	End: number,
}

export type SerialHold = {
	Id: Name,
	Count: number,
	End: number,
	First: number,
}

export type SerialRun = {
	First: number,
	Count: number,
}

type PartHead = {
	Fingerprint: number?,
	IsSealed: boolean,
	IsClosed: boolean,
	IsFinal: boolean,
	OpenedAt: number?,
	Sold: number,
	Carried: { FieldAmount },
}

export type PlainPart = PartHead & {
	IsSerial: false,
	Holds: { Hold },
}

export type SerialPart = PartHead & {
	IsSerial: true,
	SerialNext: number,
	SerialEnd: number,
	Holds: { SerialHold },
	Returned: { SerialRun },
}

export type PartRecord = PlainPart | SerialPart

export type StoredPart = {
	Record: PartRecord,
	Free: number,
	Proceeds: { FieldAmount },
}

local NewWriter = Format.NewWriter
local ReadWhole = Format.ReadWhole
local ToString = Format.ToString
local Malformed = Format.Malformed
local WriteVarint = Format.WriteVarint
local ReadVarint = Format.ReadVarint
local WriteFixedNumber = Format.WriteFixedNumber
local ReadFixedNumber = Format.ReadFixedNumber
local WriteCharacter = Format.WriteCharacter
local ReadCharacter = Format.ReadCharacter

local WriteName = Names.WriteName
local ReadName = Names.ReadName

local WriteFieldAmounts = Losses.WriteFieldAmounts
local ReadFieldAmounts = Losses.ReadFieldAmounts
local Append = Losses.Append
local WritePlainSignedNumber = Wide.WritePlainSignedNumber
local ReadSignedNumber = Wide.ReadSignedNumber

local SignedStoredOf = Balances.SignedStoredOf
local IsStorableAmount = Balances.IsStorableAmount
local SignedValueOf = Balances.SignedValueOf
local NameBefore = Timed.NameBefore

local PartSealedBit = Hot.PartSealedBit
local PartClosedBit = Hot.PartClosedBit
local PartSerialBit = Hot.PartSerialBit
local PartFinalBit = Hot.PartFinalBit
local PartFlagsMost = Hot.PartFlagsMost
local EncodeStartBytes = Record.EncodeStartBytes
local VarintLimit = Record.VarintLimit
local PartRecordKey = Hot.PartRecordKey
local FreeField = Hot.FreeField

local ModuleName = "Part"

local UnknownPartFlags = "a part holds flags that are not sealed, closed, serial or final"
local FirstNotBelowEnd = "a serial run starts at or past the end of its part's range"
local UnitsPastSerials = "a serial part holds more free units than serials left"
local UnitsPastLimit = "a part's free units and held units add up to 2^53 or more"
local HoldEndTooLarge = "a hold ends at a stamp of 2^53 or more"
local ProceedsRepeat = "a proceeds field is named u or appears twice"
local AmountNotRead = "a proceeds amount is not one its field's arithmetic wrote"
local AmountNotWritable = "a proceeds amount reads as a value its arithmetic encodes as no storable text"
local NoPartRecord =
	`{ModuleName}: a part's state holds its record under a key no field can be. The caller must give one`
local FreeNotANumber = `{ModuleName}: a part's state holds its free units under u as a number. The caller must give one`
local WriteFirstNotBelowEnd =
	`{ModuleName}: a serial hold or run starts below its part's end. The caller must give a lower first serial`
local WriteUnopened = `{ModuleName}: a part is written with its fp and t_open. The caller must give an opened part`

local function HoldBefore(Left: Hold, Right: Hold): boolean
	return NameBefore(Left.Id, Right.Id)
end

local function RunBefore(Left: SerialRun, Right: SerialRun): boolean
	return Left.First > Right.First
end

local function WriteList<Item>(
	Out: Writer,
	Items: { Item },
	Before: (Left: Item, Right: Item) -> boolean,
	WriteOne: (Out: Writer, Item: Item) -> ()
)
	WriteVarint(Out, #Items)
	local Sorted = table.clone(Items)
	table.sort(Sorted, Before)
	for _, Item in Sorted do
		WriteOne(Out, Item)
	end
end

local function ReadList<Item>(
	In: Reader,
	ReadOne: (In: Reader) -> Item,
	Before: (Left: Item, Right: Item) -> boolean
): { Item }
	local Items: { Item } = {}
	for _ = 1, ReadVarint(In) do
		Append(Items, ReadOne(In), Before)
	end
	return Items
end

local function WriteFlags(Out: Writer, Part: PartRecord)
	local Flags = 0
	if Part.IsSealed then
		Flags += PartSealedBit
	end
	if Part.IsClosed then
		Flags += PartClosedBit
	end
	if Part.IsSerial then
		Flags += PartSerialBit
	end
	if Part.IsFinal then
		Flags += PartFinalBit
	end
	WriteCharacter(Out, Flags)
end

local function ReadFlags(In: Reader): number
	local Flags = ReadCharacter(In)
	if Flags > PartFlagsMost then
		Malformed(UnknownPartFlags)
	end
	return Flags
end

local function WriteFirst(Out: Writer, SerialEnd: number, First: number)
	if First >= SerialEnd then
		error(WriteFirstNotBelowEnd)
	end
	WriteVarint(Out, SerialEnd - 1 - First)
end

local function ReadFirst(In: Reader, SerialEnd: number): number
	local First = SerialEnd - 1 - ReadVarint(In)
	if First < 0 then
		Malformed(FirstNotBelowEnd)
	end
	return First
end

local function RequireUnitsBelowLimit(Free: number, Held: number)
	if Free + Held >= VarintLimit then
		Malformed(UnitsPastLimit)
	end
end

local function WriteHold(Out: Writer, Hold: Hold, OpenedAt: number)
	WriteName(Out, Hold.Id)
	WriteVarint(Out, Hold.Count)
	WritePlainSignedNumber(Out, Hold.End - OpenedAt)
end

local function ReadHold(In: Reader, OpenedAt: number): Hold
	local Hold: Hold = {
		Id = ReadName(In),
		Count = ReadVarint(In),
		End = OpenedAt + ReadSignedNumber(In),
	}
	if math.abs(Hold.End) >= VarintLimit then
		Malformed(HoldEndTooLarge)
	end
	return Hold
end

local function WriteSerialHold(Out: Writer, Hold: SerialHold, OpenedAt: number, SerialEnd: number)
	WriteHold(Out, Hold, OpenedAt)
	WriteFirst(Out, SerialEnd, Hold.First)
end

local function ReadSerialHold(In: Reader, OpenedAt: number, SerialEnd: number): SerialHold
	local Hold = ReadHold(In, OpenedAt)
	return { Id = Hold.Id, Count = Hold.Count, End = Hold.End, First = ReadFirst(In, SerialEnd) }
end

local function WriteRun(Out: Writer, Run: SerialRun, SerialEnd: number)
	WriteFirst(Out, SerialEnd, Run.First)
	WriteVarint(Out, Run.Count)
end

local function ReadRun(In: Reader, SerialEnd: number): SerialRun
	return { First = ReadFirst(In, SerialEnd), Count = ReadVarint(In) }
end

local function WritePartText(Stored: StoredPart): string
	local Part = Stored.Record
	local Fingerprint = Part.Fingerprint
	local OpenedAt = Part.OpenedAt
	if Fingerprint == nil or OpenedAt == nil then
		error(WriteUnopened)
	end
	local Out = NewWriter(EncodeStartBytes)
	WriteFixedNumber(Out, Fingerprint)
	WriteFlags(Out, Part)
	WriteVarint(Out, OpenedAt)
	WriteVarint(Out, Stored.Free)
	WriteVarint(Out, Part.Sold)
	WriteFieldAmounts(Out, Stored.Proceeds)
	if not Part.IsSerial then
		WriteList(Out, Part.Holds, HoldBefore, function(Sink: Writer, Hold: Hold)
			WriteHold(Sink, Hold, OpenedAt)
		end)
		return ToString(Out)
	end
	local SerialEnd = Part.SerialEnd
	WriteVarint(Out, Part.SerialNext)
	WriteVarint(Out, SerialEnd)
	WriteList(Out, Part.Holds, HoldBefore, function(Sink: Writer, Hold: SerialHold)
		WriteSerialHold(Sink, Hold, OpenedAt, SerialEnd)
	end)
	WriteList(Out, Part.Returned, RunBefore, function(Sink: Writer, Run: SerialRun)
		WriteRun(Sink, Run, SerialEnd)
	end)
	return ToString(Out)
end

local function ReadPart(In: Reader): StoredPart
	local Fingerprint = ReadFixedNumber(In)
	local Flags = ReadFlags(In)
	local OpenedAt = ReadVarint(In)
	local Free = ReadVarint(In)
	local Sold = ReadVarint(In)
	local Proceeds = ReadFieldAmounts(In)
	local IsSealed = bit32.btest(Flags, PartSealedBit)
	local IsClosed = bit32.btest(Flags, PartClosedBit)
	local IsFinal = bit32.btest(Flags, PartFinalBit)
	if not bit32.btest(Flags, PartSerialBit) then
		local Holds = ReadList(In, function(Source: Reader): Hold
			return ReadHold(Source, OpenedAt)
		end, HoldBefore)
		local HeldUnits = 0
		for _, Held in Holds do
			HeldUnits += Held.Count
		end
		RequireUnitsBelowLimit(Free, HeldUnits)
		local Plain: PlainPart = {
			Fingerprint = Fingerprint,
			IsSealed = IsSealed,
			IsClosed = IsClosed,
			IsFinal = IsFinal,
			IsSerial = false,
			OpenedAt = OpenedAt,
			Sold = Sold,
			Carried = {},
			Holds = Holds,
		}
		return { Record = Plain, Free = Free, Proceeds = Proceeds }
	end
	local SerialNext = ReadVarint(In)
	local SerialEnd = ReadVarint(In)
	local Holds = ReadList(In, function(Source: Reader): SerialHold
		return ReadSerialHold(Source, OpenedAt, SerialEnd)
	end, HoldBefore)
	local Returned = ReadList(In, function(Source: Reader): SerialRun
		return ReadRun(Source, SerialEnd)
	end, RunBefore)
	local HeldUnits = 0
	for _, Held in Holds do
		HeldUnits += Held.Count
	end
	RequireUnitsBelowLimit(Free, HeldUnits)
	local SerialsLeft = SerialEnd - SerialNext
	for _, Run in Returned do
		SerialsLeft += Run.Count
	end
	if Free > SerialsLeft then
		Malformed(UnitsPastSerials)
	end
	local Serial: SerialPart = {
		Fingerprint = Fingerprint,
		IsSealed = IsSealed,
		IsClosed = IsClosed,
		IsFinal = IsFinal,
		IsSerial = true,
		OpenedAt = OpenedAt,
		Sold = Sold,
		Carried = {},
		SerialNext = SerialNext,
		SerialEnd = SerialEnd,
		Holds = Holds,
		Returned = Returned,
	}
	return { Record = Serial, Free = Free, Proceeds = Proceeds }
end

local function RecordOf(State: Fields): PartRecord
	local Held = State[PartRecordKey]
	if type(Held) ~= "table" then
		error(NoPartRecord)
	end
	return Held :: PartRecord
end

local function FreeOf(State: Fields): number
	local Free = State[FreeField]
	if type(Free) ~= "number" then
		error(FreeNotANumber)
	end
	return Free
end

local function ProceedsValue(Entry: FieldAmount, Arithmetic: Arithmetic): unknown
	local Held = SignedValueOf(Entry.Amount, Arithmetic)
	if Held == nil then
		return Malformed(AmountNotRead)
	end
	if not IsStorableAmount(SignedStoredOf(Held, Arithmetic)) then
		return Malformed(AmountNotWritable)
	end
	return Held
end

local function StateOfText(Text: string, Arithmetics: { [string]: Arithmetic }): Fields
	local Stored = ReadWhole(Text, ReadPart)
	local State: Fields = { [FreeField] = Stored.Free, [PartRecordKey] = Stored.Record }
	local Seen: { [string]: boolean } = { [FreeField] = true }
	for _, Entry in Stored.Proceeds do
		if Seen[Entry.Field] then
			Malformed(ProceedsRepeat)
		end
		Seen[Entry.Field] = true
		local Arithmetic = Arithmetics[Entry.Field]
		if Arithmetic == nil then
			table.insert(Stored.Record.Carried, Entry)
		else
			State[Entry.Field] = ProceedsValue(Entry, Arithmetic)
		end
	end
	return State
end

local function ProceedsOf(State: Fields, Arithmetics: { [string]: Arithmetic }): { FieldAmount }
	local ProceedsFields: { string } = {}
	for Field in Arithmetics do
		if Field ~= FreeField and State[Field] ~= nil then
			table.insert(ProceedsFields, Field)
		end
	end
	table.sort(ProceedsFields)
	local Proceeds: { FieldAmount } = {}
	for _, Field in ProceedsFields do
		table.insert(Proceeds, { Field = Field, Amount = SignedStoredOf(State[Field], Arithmetics[Field]) })
	end
	return Proceeds
end

local function TextOfState(State: Fields, Arithmetics: { [string]: Arithmetic }): string
	local Free = FreeOf(State)
	local Held = RecordOf(State)
	local Proceeds = ProceedsOf(State, Arithmetics)
	table.move(Held.Carried, 1, #Held.Carried, #Proceeds + 1, Proceeds)
	return WritePartText({ Record = Held, Free = Free, Proceeds = Proceeds })
end

return {
	RecordOf = RecordOf,
	FreeOf = FreeOf,
	StateOfText = StateOfText,
	TextOfState = TextOfState,
}
