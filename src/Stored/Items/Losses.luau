--!strict
--!optimize 2

--[=[
	Losses: the items of the loss rooms L and S (spec/protocols/record/Format.md 6, 7.7) and the run of them
	a seal holds (9).

	A stamp in a room is an offset from the epoch of b, and in a seal it is absolute. Readers check
	representation only, and throw through Format.Malformed.

	Return type: A plain table of functions, and the types of the items.
	Example usage:
		local Out = Format.NewWriter(64)
		Losses.WriteEvent(Out, {
			Cause = "Reset",
			Name = { Kind = "Drawn", Server = 37, Counter = 5 },
			Stamp = 30,
			Fields = { { Field = "Gold", Amount = { Kind = "Default", IsNegative = true, High = 0, Low = 50 } } },
		}, 10)
		Format.ToString(Out) --> "RAhFFUBHGoldjE"
--]=]

local Alphabet = require("../../Encoding/Alphabet")
local Amounts = require("../../Encoding/Amounts")
local Format = require("../../Encoding/Format")
local Names = require("../../Encoding/Names")
local Record = require("../../Constants/Record")
local Timed = require("./Timed")

type Writer = Format.Writer
type Reader = Format.Reader
type Name = Names.Name
type KeyReference = Names.KeyReference
type SignedAmount = Amounts.SignedAmount
type CutKind = Timed.CutKind

export type ReturnCause = "Returned" | "Orphan"

export type FieldAmount = {
	Field: string,
	Amount: SignedAmount,
}

export type Event = {
	Cause: CutKind,
	Name: Name,
	Stamp: number,
	Fields: { FieldAmount },
	Fingerprint: number?,
}

export type NamedReturn = {
	Cause: ReturnCause,
	Name: Name,
	Stamp: number,
	OtherKey: KeyReference,
	Escrow: FieldAmount?,
	Fingerprint: number?,
}

export type FoldSlot = {
	Period: number,
	Count: number,
	Sums: { FieldAmount },
}

export type LossItems = {
	Events: { Event },
	Returns: { NamedReturn },
}

export type LossRecords = {
	Events: { Event },
	Returns: { NamedReturn },
	Slots: { FoldSlot },
}

local Values = Alphabet.Values

local NewWriter = Format.NewWriter
local Malformed = Format.Malformed
local WriteVarint = Format.WriteVarint
local ReadVarint = Format.ReadVarint
local WriteCharacter = Format.WriteCharacter
local ReadCharacter = Format.ReadCharacter
local WrittenBefore = Format.WrittenBefore

local WriteStored = Names.WriteStored
local ReadStored = Names.ReadStored
local WriteName = Names.WriteName
local ReadName = Names.ReadName
local WriteKey = Names.WriteKey
local WriteTaggedKey = Names.WriteTaggedKey
local ReadTaggedKey = Names.ReadTaggedKey

local WriteSignedAmount = Amounts.WriteSignedAmount
local ReadSignedAmount = Amounts.ReadSignedAmount

local StampThenName = Timed.StampThenName
local CutKindIndex = Timed.CutKindIndex
local CutKindOfIndex = Timed.CutKindOfIndex
local ReadCutKind = Timed.ReadCutKind
local WriteNameFingerprint = Timed.WriteNameFingerprint
local ReadNameFingerprint = Timed.ReadNameFingerprint
local WriteRoomStamp = Timed.WriteRoomStamp
local ReadRoomStamp = Timed.ReadRoomStamp

local AbsoluteStamps = 0

local ReturnCauseIndex: { [ReturnCause]: number } = {
	Returned = buffer.readu8(Values, Record.ReturnCauseByte.Returned),
	Orphan = buffer.readu8(Values, Record.ReturnCauseByte.Orphan),
}
local ReturnCauseOfIndex: { [number]: ReturnCause } = {}
for Cause, Index in ReturnCauseIndex do
	ReturnCauseOfIndex[Index] = Cause
end

local EscrowNoneIndex = buffer.readu8(Values, Record.ReturnEscrowByte.None)
local EscrowSomeIndex = buffer.readu8(Values, Record.ReturnEscrowByte.Some)
local SlotIndex = buffer.readu8(Values, Record.SlotByte)

local LeftScratch = NewWriter(Record.MarkMax)
local RightScratch = NewWriter(Record.MarkMax)

local NotALossItem = "an item starts with a head that is not one this run may hold"
local NotASlot = "a fold slot starts with a character that is not the slot's"
local NotAReturnCause = "a named return starts with a character that is not a return cause's"
local UnknownEscrowHead = "a named return holds a character that is neither no escrow mark nor an escrow mark"
local GroupsOutOfOrder = "an event follows a named return or a slot, or a named return follows a slot"
local ItemsDescend = "items of one kind descend by their order"

local function WriteFieldAmount(Out: Writer, Entry: FieldAmount)
	WriteStored(Out, Entry.Field)
	WriteSignedAmount(Out, Entry.Amount)
end

local function ReadFieldAmount(In: Reader): FieldAmount
	return { Field = ReadStored(In), Amount = ReadSignedAmount(In) }
end

local function WriteFieldAmounts(Out: Writer, Fields: { FieldAmount })
	WriteVarint(Out, #Fields)
	for _, Entry in Fields do
		WriteFieldAmount(Out, Entry)
	end
end

local function ReadFieldAmounts(In: Reader): { FieldAmount }
	local Count = ReadVarint(In)
	local Fields: { FieldAmount } = {}
	for Index = 1, Count do
		Fields[Index] = ReadFieldAmount(In)
	end
	return Fields
end

local function WriteEvent(Out: Writer, Event: Event, Epoch: number)
	WriteCharacter(Out, CutKindIndex[Event.Cause])
	WriteName(Out, Event.Name)
	WriteRoomStamp(Out, Event.Stamp, Epoch)
	WriteFieldAmounts(Out, Event.Fields)
	WriteNameFingerprint(Out, Event.Name, Event.Fingerprint)
end

local function ReadEvent(In: Reader, Cause: CutKind, Epoch: number): Event
	local Entry: Event = {
		Cause = Cause,
		Name = ReadName(In),
		Stamp = ReadRoomStamp(In, Epoch),
		Fields = ReadFieldAmounts(In),
	}
	Entry.Fingerprint = ReadNameFingerprint(In, Entry.Name)
	return Entry
end

local function ReadResetEvent(In: Reader, Epoch: number): Event
	if ReadCutKind(In) ~= "Reset" then
		Malformed(NotALossItem)
	end
	return ReadEvent(In, "Reset", Epoch)
end

local function WriteNamedReturn(Out: Writer, Return: NamedReturn, Epoch: number)
	WriteCharacter(Out, ReturnCauseIndex[Return.Cause])
	WriteName(Out, Return.Name)
	WriteRoomStamp(Out, Return.Stamp, Epoch)
	WriteTaggedKey(Out, Return.OtherKey)
	local Escrow = Return.Escrow
	if Escrow == nil then
		WriteCharacter(Out, EscrowNoneIndex)
	else
		WriteCharacter(Out, EscrowSomeIndex)
		WriteFieldAmount(Out, Escrow)
	end
	WriteNameFingerprint(Out, Return.Name, Return.Fingerprint)
end

local function ReadNamedReturn(In: Reader, Cause: ReturnCause, Epoch: number): NamedReturn
	local Entry: NamedReturn = {
		Cause = Cause,
		Name = ReadName(In),
		Stamp = ReadRoomStamp(In, Epoch),
		OtherKey = ReadTaggedKey(In),
	}
	local EscrowHead = ReadCharacter(In)
	if EscrowHead == EscrowSomeIndex then
		Entry.Escrow = ReadFieldAmount(In)
	elseif EscrowHead ~= EscrowNoneIndex then
		Malformed(UnknownEscrowHead)
	end
	Entry.Fingerprint = ReadNameFingerprint(In, Entry.Name)
	return Entry
end

local function ReadReturnCause(In: Reader): ReturnCause
	local Cause = ReturnCauseOfIndex[ReadCharacter(In)]
	if Cause == nil then
		Malformed(NotAReturnCause)
	end
	return Cause
end

local function ReadNamedReturnWithCause(In: Reader, Epoch: number): NamedReturn
	return ReadNamedReturn(In, ReadReturnCause(In), Epoch)
end

local function WriteFoldSlot(Out: Writer, Slot: FoldSlot)
	WriteCharacter(Out, SlotIndex)
	WriteVarint(Out, Slot.Period)
	WriteVarint(Out, Slot.Count)
	WriteFieldAmounts(Out, Slot.Sums)
end

local function ReadFoldSlotAfterHead(In: Reader): FoldSlot
	return { Period = ReadVarint(In), Count = ReadVarint(In), Sums = ReadFieldAmounts(In) }
end

local function ReadFoldSlot(In: Reader): FoldSlot
	if ReadCharacter(In) ~= SlotIndex then
		Malformed(NotASlot)
	end
	return ReadFoldSlotAfterHead(In)
end

local function KeyBefore(Left: KeyReference, Right: KeyReference): boolean
	LeftScratch.Cursor = 0
	RightScratch.Cursor = 0
	WriteKey(LeftScratch, Left)
	WriteKey(RightScratch, Right)
	return WrittenBefore(LeftScratch, RightScratch)
end

local function EventBefore(Left: Event, Right: Event): boolean
	if StampThenName(Left.Stamp, Left.Name, Right.Stamp, Right.Name) then
		return true
	end
	if StampThenName(Right.Stamp, Right.Name, Left.Stamp, Left.Name) then
		return false
	end
	return CutKindIndex[Left.Cause] < CutKindIndex[Right.Cause]
end

local function ReturnBefore(Left: NamedReturn, Right: NamedReturn): boolean
	if StampThenName(Left.Stamp, Left.Name, Right.Stamp, Right.Name) then
		return true
	end
	if StampThenName(Right.Stamp, Right.Name, Left.Stamp, Left.Name) then
		return false
	end
	return KeyBefore(Left.OtherKey, Right.OtherKey)
end

local function SlotBefore(Left: FoldSlot, Right: FoldSlot): boolean
	return Left.Period < Right.Period
end

local function LossCount(Items: LossItems): number
	return #Items.Events + #Items.Returns
end

local function WriteLossRoom(Out: Writer, Items: LossItems, Epoch: number)
	for _, Event in Items.Events do
		WriteEvent(Out, Event, Epoch)
	end
	for _, Return in Items.Returns do
		WriteNamedReturn(Out, Return, Epoch)
	end
end

local function WriteSealRecords(Out: Writer, Records: LossRecords)
	WriteVarint(Out, LossCount(Records) + #Records.Slots)
	WriteLossRoom(Out, Records, AbsoluteStamps)
	for _, Slot in Records.Slots do
		WriteFoldSlot(Out, Slot)
	end
end

local function Append<Entry>(Entries: { Entry }, New: Entry, Before: (Entry, Entry) -> boolean)
	local Previous = Entries[#Entries]
	if Previous ~= nil and Before(New, Previous) then
		Malformed(ItemsDescend)
	end
	table.insert(Entries, New)
end

local function TakeEvent(In: Reader, Items: LossItems, HasSlots: boolean, Cause: CutKind, Epoch: number)
	if #Items.Returns > 0 or HasSlots then
		Malformed(GroupsOutOfOrder)
	end
	Append(Items.Events, ReadEvent(In, Cause, Epoch), EventBefore)
end

local function TakeReturn(In: Reader, Items: LossItems, HasSlots: boolean, Cause: ReturnCause, Epoch: number)
	if HasSlots then
		Malformed(GroupsOutOfOrder)
	end
	Append(Items.Returns, ReadNamedReturn(In, Cause, Epoch), ReturnBefore)
end

local function ReadLossRoom(In: Reader, Count: number, Epoch: number): LossItems
	local Items: LossItems = { Events = {}, Returns = {} }
	for _ = 1, Count do
		local Head = ReadCharacter(In)
		local ReturnCause = ReturnCauseOfIndex[Head]
		if CutKindOfIndex[Head] == "Reset" then
			TakeEvent(In, Items, false, "Reset", Epoch)
		elseif ReturnCause ~= nil then
			TakeReturn(In, Items, false, ReturnCause, Epoch)
		else
			Malformed(NotALossItem)
		end
	end
	return Items
end

local function ReadSealRecords(In: Reader): LossRecords
	local Records: LossRecords = { Events = {}, Returns = {}, Slots = {} }
	for _ = 1, ReadVarint(In) do
		local Head = ReadCharacter(In)
		local EventCause = CutKindOfIndex[Head]
		local ReturnCause = ReturnCauseOfIndex[Head]
		if EventCause ~= nil then
			TakeEvent(In, Records, #Records.Slots > 0, EventCause, AbsoluteStamps)
		elseif ReturnCause ~= nil then
			TakeReturn(In, Records, #Records.Slots > 0, ReturnCause, AbsoluteStamps)
		elseif Head == SlotIndex then
			Append(Records.Slots, ReadFoldSlotAfterHead(In), SlotBefore)
		else
			Malformed(NotALossItem)
		end
	end
	return Records
end

return {
	WriteEvent = WriteEvent,
	ReadEvent = ReadEvent,
	ReadResetEvent = ReadResetEvent,
	WriteNamedReturn = WriteNamedReturn,
	ReadNamedReturn = ReadNamedReturn,
	ReadNamedReturnWithCause = ReadNamedReturnWithCause,
	WriteFieldAmounts = WriteFieldAmounts,
	ReadFieldAmounts = ReadFieldAmounts,
	Append = Append,
	WriteFoldSlot = WriteFoldSlot,
	ReadFoldSlot = ReadFoldSlot,
	EventBefore = EventBefore,
	ReturnBefore = ReturnBefore,
	SlotBefore = SlotBefore,
	LossCount = LossCount,
	WriteLossRoom = WriteLossRoom,
	ReadLossRoom = ReadLossRoom,
	WriteSealRecords = WriteSealRecords,
	ReadSealRecords = ReadSealRecords,
}
