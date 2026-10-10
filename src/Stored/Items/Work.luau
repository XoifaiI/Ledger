--!strict
--!optimize 2

--[=[
	Work: the items of the room P (spec/protocols/record/Format.md 7.5): escrow marks, exclusive marks and
	pinned records.

	Bit 3 on an exclusive mark says a slot path follows, bit 4 says the part follows the name, bit 5 says a
	key reference is to another store or scope. The writer throws on a zero escrow amount. A reader throws through
	Format.Malformed.

	Return type: A plain table of functions, and the types of the marks.
	Example usage:
		local Out = Format.NewWriter(64)
		Work.WriteMark(Out, {
			Kind = "Exclusive",
			IsClean = true,
			Opening = { Attempt = 1, Name = { Kind = "Drawn", Server = 37, Counter = 5 }, Stamp = 2 },
			Decider = { Kind = "Short", Key = "Bob" },
		}, 0)
		Format.ToString(Out) --> "FBAhFFCFBob"
--]=]

local Amounts = require("../../Encoding/Amounts")
local Format = require("../../Encoding/Format")
local Names = require("../../Encoding/Names")
local Post = require("../Post")
local Record = require("../../Constants/Record")
local SlotPath = require("./SlotPath")
local Timed = require("./Timed")
local Transaction = require("../../Constants/Transaction")

type Writer = Format.Writer
type Reader = Format.Reader
type Name = Names.Name
type KeyReference = Names.KeyReference
type UnsignedAmount = Amounts.UnsignedAmount
type PathStep = Post.PathStep

export type MarkOpening = {
	Attempt: number,
	Name: Name,
	Part: number?,
	Stamp: number,
	Fingerprint: number?,
}

export type EscrowMark = {
	Kind: "Escrow",
	IsClean: boolean,
	Opening: MarkOpening,
	Decider: KeyReference,
	Field: string,
	Amount: UnsignedAmount,
	IsDebit: boolean,
}

export type ExclusiveMark = {
	Kind: "Exclusive",
	IsClean: boolean,
	Opening: MarkOpening,
	Decider: KeyReference,
	Slot: { PathStep }?,
}

export type PinnedRecord = {
	Kind: "Pinned",
	IsClean: boolean,
	Opening: MarkOpening,
	OtherLegs: { KeyReference },
	DeciderValue: number?,
}

export type StandingMark = EscrowMark | ExclusiveMark

export type Mark = StandingMark | PinnedRecord

local Malformed = Format.Malformed
local WriteVarint = Format.WriteVarint
local ReadVarint = Format.ReadVarint
local WriteCharacter = Format.WriteCharacter
local ReadCharacter = Format.ReadCharacter

local WriteName = Names.WriteName
local ReadName = Names.ReadName
local WriteStored = Names.WriteStored
local ReadStored = Names.ReadStored
local WriteKey = Names.WriteKey
local ReadShortKey = Names.ReadShortKey
local WriteTaggedKey = Names.WriteTaggedKey
local ReadTaggedKey = Names.ReadTaggedKey

local IsZeroAmount = Amounts.IsZeroAmount
local WriteUnsignedAmount = Amounts.WriteUnsignedAmount
local ReadUnsignedAmount = Amounts.ReadUnsignedAmount

local StampNamePartBefore = Timed.StampNamePartBefore
local WriteNameFingerprint = Timed.WriteNameFingerprint
local ReadNameFingerprint = Timed.ReadNameFingerprint
local WriteRoomStamp = Timed.WriteRoomStamp
local ReadRoomStamp = Timed.ReadRoomStamp

local WorkKind = Record.WorkKind
local WorkCleanBit = Record.WorkCleanBit
local WorkSignOrSlotBit = Record.WorkSignOrSlotBit
local WorkSubBit = Record.WorkSubBit
local WorkForeignBit = Record.WorkForeignBit
local WorkKindMask = Record.WorkKindMask
local MaxAttempts = Transaction.MaxAttempts

local WriteSlotPath = SlotPath.WriteSlotPath
local ReadSlotPath = SlotPath.ReadSlotPath

local ModuleName = "Work"

local ZeroEscrowAmount = `{ModuleName}: an escrow mark's amount is above zero. The caller must give a positive one`
local ZeroAmountStored = "an escrow mark holds an amount of zero, which the writer never writes"
local KeyFormsMismatch =
	"a work item's head disagrees with its key references on whether any is to another store or scope"
local BitOnPinned = "a pinned record has bit 3 set in its head, which is an escrow mark's sign or a slot path"
local AttemptOutOfRange = `a work item's attempt is not from 1 to {MaxAttempts}`
local WriteAttemptOutOfRange =
	`{ModuleName}: a work item's attempt is from 1 to {MaxAttempts}. The caller must give one in that range`

local function WriteOpening(Out: Writer, Opening: MarkOpening, Epoch: number)
	if Opening.Attempt < 1 or Opening.Attempt > MaxAttempts then
		error(WriteAttemptOutOfRange)
	end
	WriteVarint(Out, Opening.Attempt)
	WriteName(Out, Opening.Name)
	if Opening.Part ~= nil then
		WriteCharacter(Out, Opening.Part)
	end
	WriteRoomStamp(Out, Opening.Stamp, Epoch)
	WriteNameFingerprint(Out, Opening.Name, Opening.Fingerprint)
end

local function ReadOpening(In: Reader, Head: number, Epoch: number): MarkOpening
	local Attempt = ReadVarint(In)
	if Attempt < 1 or Attempt > MaxAttempts then
		Malformed(AttemptOutOfRange)
	end
	local Name = ReadName(In)
	local Part: number? = nil
	if bit32.btest(Head, WorkSubBit) then
		Part = ReadCharacter(In)
	end
	local Stamp = ReadRoomStamp(In, Epoch)
	return { Attempt = Attempt, Name = Name, Part = Part, Stamp = Stamp, Fingerprint = ReadNameFingerprint(In, Name) }
end

local function HasFullKey(Mark: Mark): boolean
	if Mark.Kind ~= "Pinned" then
		return Mark.Decider.Kind == "Full"
	end
	for _, Leg in Mark.OtherLegs do
		if Leg.Kind == "Full" then
			return true
		end
	end
	return false
end

local function KindCodeOf(Mark: Mark): number
	if Mark.Kind == "Pinned" then
		if Mark.DeciderValue ~= nil then
			return WorkKind.PinnedValue
		end
		return WorkKind.Pinned
	end
	if Mark.Kind == "Escrow" then
		return WorkKind.Escrow
	end
	return WorkKind.Exclusive
end

local function WorkHead(Mark: Mark): number
	local Head = KindCodeOf(Mark)
	if Mark.IsClean then
		Head += WorkCleanBit
	end
	if Mark.Kind == "Escrow" and Mark.IsDebit then
		Head += WorkSignOrSlotBit
	end
	if Mark.Kind == "Exclusive" and Mark.Slot ~= nil then
		Head += WorkSignOrSlotBit
	end
	if Mark.Opening.Part ~= nil then
		Head += WorkSubBit
	end
	if HasFullKey(Mark) then
		Head += WorkForeignBit
	end
	return Head
end

local function WriteMarkKey(Out: Writer, Reference: KeyReference, IsTagged: boolean)
	if IsTagged then
		WriteTaggedKey(Out, Reference)
		return
	end
	WriteKey(Out, Reference)
end

local function ReadMarkKey(In: Reader, IsTagged: boolean): KeyReference
	if IsTagged then
		return ReadTaggedKey(In)
	end
	return ReadShortKey(In)
end

local function WriteMark(Out: Writer, Mark: Mark, Epoch: number)
	local Head = WorkHead(Mark)
	local IsTagged = bit32.btest(Head, WorkForeignBit)
	WriteCharacter(Out, Head)
	WriteOpening(Out, Mark.Opening, Epoch)
	if Mark.Kind == "Escrow" then
		if IsZeroAmount(Mark.Amount) then
			error(ZeroEscrowAmount)
		end
		WriteMarkKey(Out, Mark.Decider, IsTagged)
		WriteStored(Out, Mark.Field)
		WriteUnsignedAmount(Out, Mark.Amount)
		return
	end
	if Mark.Kind == "Exclusive" then
		WriteMarkKey(Out, Mark.Decider, IsTagged)
		if Mark.Slot ~= nil then
			WriteSlotPath(Out, Mark.Slot)
		end
		return
	end
	WriteVarint(Out, #Mark.OtherLegs)
	for _, Leg in Mark.OtherLegs do
		WriteMarkKey(Out, Leg, IsTagged)
	end
	if Mark.DeciderValue ~= nil then
		WriteVarint(Out, Mark.DeciderValue)
	end
end

local function ReadEscrow(In: Reader, Head: number, Epoch: number): EscrowMark
	local IsTagged = bit32.btest(Head, WorkForeignBit)
	local Mark: EscrowMark = {
		Kind = "Escrow",
		IsClean = bit32.btest(Head, WorkCleanBit),
		Opening = ReadOpening(In, Head, Epoch),
		Decider = ReadMarkKey(In, IsTagged),
		Field = ReadStored(In),
		Amount = ReadUnsignedAmount(In),
		IsDebit = bit32.btest(Head, WorkSignOrSlotBit),
	}
	if IsZeroAmount(Mark.Amount) then
		Malformed(ZeroAmountStored)
	end
	return Mark
end

local function ReadExclusive(In: Reader, Head: number, Epoch: number): ExclusiveMark
	local IsTagged = bit32.btest(Head, WorkForeignBit)
	local Mark: ExclusiveMark = {
		Kind = "Exclusive",
		IsClean = bit32.btest(Head, WorkCleanBit),
		Opening = ReadOpening(In, Head, Epoch),
		Decider = ReadMarkKey(In, IsTagged),
	}
	if bit32.btest(Head, WorkSignOrSlotBit) then
		Mark.Slot = ReadSlotPath(In)
	end
	return Mark
end

local function ReadPinned(In: Reader, Head: number, Epoch: number): PinnedRecord
	local IsTagged = bit32.btest(Head, WorkForeignBit)
	local Pinned: PinnedRecord = {
		Kind = "Pinned",
		IsClean = bit32.btest(Head, WorkCleanBit),
		Opening = ReadOpening(In, Head, Epoch),
		OtherLegs = {},
	}
	for _ = 1, ReadVarint(In) do
		table.insert(Pinned.OtherLegs, ReadMarkKey(In, IsTagged))
	end
	if bit32.band(Head, WorkKindMask) == WorkKind.PinnedValue then
		Pinned.DeciderValue = ReadVarint(In)
	end
	return Pinned
end

local ReaderOfKind: { [number]: (In: Reader, Head: number, Epoch: number) -> Mark } = {
	[WorkKind.Escrow] = ReadEscrow,
	[WorkKind.Exclusive] = ReadExclusive,
	[WorkKind.Pinned] = ReadPinned,
	[WorkKind.PinnedValue] = ReadPinned,
}

local function ReadMark(In: Reader, Epoch: number): Mark
	local Head = ReadCharacter(In)
	local Kind = bit32.band(Head, WorkKindMask)
	if bit32.btest(Head, WorkSignOrSlotBit) and Kind ~= WorkKind.Escrow and Kind ~= WorkKind.Exclusive then
		Malformed(BitOnPinned)
	end
	local Mark = ReaderOfKind[Kind](In, Head, Epoch)
	if bit32.btest(Head, WorkForeignBit) ~= HasFullKey(Mark) then
		Malformed(KeyFormsMismatch)
	end
	return Mark
end

local function MarkBefore(Left: Mark, Right: Mark): boolean
	local LeftOpening, RightOpening = Left.Opening, Right.Opening
	return StampNamePartBefore(
		LeftOpening.Stamp,
		LeftOpening.Name,
		LeftOpening.Part,
		RightOpening.Stamp,
		RightOpening.Name,
		RightOpening.Part
	)
end

local function EscrowMarksOf(Items: { Mark }): { EscrowMark }
	local Escrows: { EscrowMark } = {}
	for _, Item in Items do
		if Item.Kind == "Escrow" then
			table.insert(Escrows, Item)
		end
	end
	return Escrows
end

return {
	EscrowMarksOf = EscrowMarksOf,
	HasFullKey = HasFullKey,
	WorkHead = WorkHead,
	WriteMarkKey = WriteMarkKey,
	ReadMarkKey = ReadMarkKey,
	WriteMark = WriteMark,
	ReadMark = ReadMark,
	MarkBefore = MarkBefore,
}
