--!strict
--!optimize 2

--[=[
	Timed: the items of the rooms T, U and K (spec/protocols/record/Format.md 6, 7.1 to 7.4): writer
	entries, named entries and cut names.

	A stamp is an offset from the epoch of b and a window is whole WindowUnits (Format). Named entries sort
	by stamp, name, part. A reader throws through Format.Malformed; the record says what belongs in a room.

	Return type: A plain table of functions, the frozen lookups CutKindIndex (kind to character) and
	CutKindOfIndex (character to kind), and the types of the items.
	Example usage:
		local Out = Format.NewWriter(64)
		Timed.WriteWriterEntry(Out, { Kind = "Writer", WriterId = 37, Highest = 3, Newest = 10, Fates = {
			{ Sequence = 2, Kind = "Refused" },
		} }, 0)
		Format.ToString(Out) --> "AhFDKBBB"
--]=]

local Alphabet = require("../../Encoding/Alphabet")
local Fates = require("./Fates")
local Format = require("../../Encoding/Format")
local Names = require("../../Encoding/Names")
local Record = require("../../Constants/Record")

type Writer = Format.Writer
type Reader = Format.Reader
type Name = Names.Name

type Fate = Fates.Fate
type WriterFateKind = Fates.WriterFateKind

export type CutKind = "Erase" | "Reset"

export type StoredName = {
	read Name: Name,
	read Part: number?,
}

export type WriterFate = {
	Sequence: number,
	Kind: WriterFateKind,
}

export type WriterEntry = {
	Kind: "Writer",
	WriterId: number,
	Highest: number,
	Newest: number,
	Fates: { WriterFate },
}

export type NamedEntry = {
	Kind: "Named",
	Fate: Fate,
	WindowSeconds: number,
	Name: StoredName,
	Stamp: number,
	Fingerprint: number?,
}

export type CutName = {
	Kind: CutKind,
	WindowSeconds: number,
	Name: Name,
	Stamp: number,
	Fingerprint: number?,
}

export type TimedItem = WriterEntry | NamedEntry

local Values = Alphabet.Values

local FateCode = Fates.FateCode
local WriteFateExtra = Fates.WriteFateExtra
local ReadFate = Fates.ReadFate
local WriteWriterFateKind = Fates.WriteWriterFateKind
local ReadWriterFateKind = Fates.ReadWriterFateKind

local NewWriter = Format.NewWriter
local Malformed = Format.Malformed
local WrittenBefore = Format.WrittenBefore
local WriteVarint = Format.WriteVarint
local RequireWholeBelow = Format.RequireWholeBelow
local ReadVarint = Format.ReadVarint
local WriteFixedNumber = Format.WriteFixedNumber
local ReadFixedNumber = Format.ReadFixedNumber
local WriteWindow = Format.WriteWindow
local ReadWindow = Format.ReadWindow
local WriteCharacter = Format.WriteCharacter
local ReadCharacter = Format.ReadCharacter

local WriteName = Names.WriteName
local ReadName = Names.ReadName
local WriteSubName = Names.WriteSubName
local ReadSubName = Names.ReadSubName

local NamedKindBase = Record.NamedKindBase
local WriterEntryHead = Record.WriterEntryHead
local FatesMax = Record.FatesMax
local VarintLimit = Record.VarintLimit

local SubNameHeadStep = 32

local NameHeaderBytes = 2
local NameScratchBytes = Record.NameMax + NameHeaderBytes
local LeftScratch = NewWriter(NameScratchBytes)
local RightScratch = NewWriter(NameScratchBytes)

local BuiltIndex: { [CutKind]: number } = {
	Erase = buffer.readu8(Values, Record.EventCauseByte.Erase),
	Reset = buffer.readu8(Values, Record.EventCauseByte.Reset),
}
local BuiltKindOfIndex: { [number]: CutKind } = {}
for Kind, Index in BuiltIndex do
	BuiltKindOfIndex[Index] = Kind
end
local CutKindIndex = table.freeze(BuiltIndex)
local CutKindOfIndex = table.freeze(BuiltKindOfIndex)

local ModuleName = "Timed"

local GameNameNeedsFingerprint = `{ModuleName}: a game name is stored with its fingerprint. The caller must give one`
local NotAnItemHead = "an item starts with a head that is neither a writer entry's nor a named entry's"
local UnknownCutKind = "a cut kind is a character that is neither erase nor reset"
local WriteFatesTooMany = `{ModuleName}: a writer entry holds at most {FatesMax} fates. The caller must give no more`
local WriteFateBeyondHighest =
	`{ModuleName}: a writer entry's fate is above its highest number. The caller must keep each fate at or below it`
local WriteFatesNotDescending =
	`{ModuleName}: a writer entry's fates descend by number, each below the one before. The caller must give them so`
local FatesTooMany = `a writer entry holds more than {FatesMax} fates`
local FateBeyondHighest = "a writer entry holds a fate above its highest number"
local FatesNotDescending = "a writer entry's fates do not descend by number"
local UntimedFate = "an untimed entry holds a fate that is not took, refused or full"
local RoomStampTooLarge = "a stamp in a room, its epoch plus its offset, is 2^53 or more"

local function WriteRoomStamp(Out: Writer, Stamp: number, Epoch: number)
	RequireWholeBelow(ModuleName, "a stamp in a room", Stamp, VarintLimit)
	WriteVarint(Out, Stamp - Epoch)
end

local function ReadRoomStamp(In: Reader, Epoch: number): number
	local Stamp = Epoch + ReadVarint(In)
	if Stamp >= VarintLimit then
		Malformed(RoomStampTooLarge)
	end
	return Stamp
end

local function WriteStoredName(Out: Writer, Stored: StoredName)
	local Part = Stored.Part
	if Part == nil then
		WriteName(Out, Stored.Name)
		return
	end
	WriteSubName(Out, Stored.Name, Part)
end

local function ReadStoredName(In: Reader, IsSub: boolean): StoredName
	if IsSub then
		return ReadSubName(In)
	end
	return { Name = ReadName(In) }
end

local function WriteNameFingerprint(Out: Writer, Name: Name, Fingerprint: number?)
	if Name.Kind == "Drawn" then
		return
	end
	if Fingerprint == nil then
		error(GameNameNeedsFingerprint)
	end
	WriteFixedNumber(Out, Fingerprint)
end

local function ReadNameFingerprint(In: Reader, Name: Name): number?
	if Name.Kind == "Drawn" then
		return nil
	end
	return ReadFixedNumber(In)
end

local function FateBefore(Left: WriterFate, Right: WriterFate): boolean
	return Left.Sequence > Right.Sequence
end

local function WriteWriterEntry(Out: Writer, Entry: WriterEntry, Epoch: number)
	WriteCharacter(Out, WriterEntryHead)
	WriteVarint(Out, Entry.WriterId)
	WriteVarint(Out, Entry.Highest)
	WriteRoomStamp(Out, Entry.Newest, Epoch)
	if #Entry.Fates > FatesMax then
		error(WriteFatesTooMany)
	end
	WriteVarint(Out, #Entry.Fates)
	local Previous: WriterFate? = nil
	for _, Fate in Entry.Fates do
		if Fate.Sequence > Entry.Highest then
			error(WriteFateBeyondHighest)
		end
		if Previous ~= nil and not FateBefore(Previous, Fate) then
			error(WriteFatesNotDescending)
		end
		WriteVarint(Out, Entry.Highest - Fate.Sequence)
		WriteWriterFateKind(Out, Fate.Kind)
		Previous = Fate
	end
end

local function ReadWriterEntry(In: Reader, Epoch: number): WriterEntry
	local Entry: WriterEntry = {
		Kind = "Writer",
		WriterId = ReadVarint(In),
		Highest = ReadVarint(In),
		Newest = ReadRoomStamp(In, Epoch),
		Fates = {},
	}
	local Count = ReadVarint(In)
	if Count > FatesMax then
		Malformed(FatesTooMany)
	end
	local Previous: WriterFate? = nil
	for _ = 1, Count do
		local Distance = ReadVarint(In)
		if Distance > Entry.Highest then
			Malformed(FateBeyondHighest)
		end
		local Fate: WriterFate = { Sequence = Entry.Highest - Distance, Kind = ReadWriterFateKind(In) }
		if Previous ~= nil and not FateBefore(Previous, Fate) then
			Malformed(FatesNotDescending)
		end
		table.insert(Entry.Fates, Fate)
		Previous = Fate
	end
	return Entry
end

local function WriteNamedEntry(Out: Writer, Entry: NamedEntry, Epoch: number, WindowUnit: number)
	local Head = NamedKindBase + FateCode(Entry.Fate)
	if Entry.Name.Part ~= nil then
		Head += SubNameHeadStep
	end
	WriteCharacter(Out, Head)
	WriteWindow(Out, Entry.WindowSeconds, WindowUnit)
	WriteStoredName(Out, Entry.Name)
	WriteRoomStamp(Out, Entry.Stamp, Epoch)
	WriteFateExtra(Out, Entry.Fate)
	WriteNameFingerprint(Out, Entry.Name.Name, Entry.Fingerprint)
end

local function ReadNamedEntry(In: Reader, Head: number, Epoch: number, WindowUnit: number): NamedEntry
	if Head < NamedKindBase then
		Malformed(NotAnItemHead)
	end
	local HeadOffset = Head - NamedKindBase
	local Entry: NamedEntry = {
		Kind = "Named",
		WindowSeconds = ReadWindow(In, WindowUnit),
		Name = ReadStoredName(In, HeadOffset >= SubNameHeadStep),
		Stamp = ReadRoomStamp(In, Epoch),
		Fate = ReadFate(In, HeadOffset % SubNameHeadStep),
	}
	Entry.Fingerprint = ReadNameFingerprint(In, Entry.Name.Name)
	return Entry
end

local function WriteTimedItem(Out: Writer, Item: TimedItem, Epoch: number, WindowUnit: number)
	if Item.Kind == "Writer" then
		WriteWriterEntry(Out, Item, Epoch)
		return
	end
	WriteNamedEntry(Out, Item, Epoch, WindowUnit)
end

local function ReadTimedItem(In: Reader, Epoch: number, WindowUnit: number): TimedItem
	local Head = ReadCharacter(In)
	if Head == WriterEntryHead then
		return ReadWriterEntry(In, Epoch)
	end
	return ReadNamedEntry(In, Head, Epoch, WindowUnit)
end

local function ReadUntimedEntry(In: Reader, Epoch: number, WindowUnit: number): NamedEntry
	local Entry = ReadNamedEntry(In, ReadCharacter(In), Epoch, WindowUnit)
	local Kind = Entry.Fate.Kind
	if Kind ~= "Took" and Kind ~= "Refused" and Kind ~= "Full" then
		Malformed(UntimedFate)
	end
	return Entry
end

local function WriteCutName(Out: Writer, Entry: CutName, Epoch: number, WindowUnit: number)
	WriteCharacter(Out, CutKindIndex[Entry.Kind])
	WriteWindow(Out, Entry.WindowSeconds, WindowUnit)
	WriteName(Out, Entry.Name)
	WriteRoomStamp(Out, Entry.Stamp, Epoch)
	WriteNameFingerprint(Out, Entry.Name, Entry.Fingerprint)
end

local function ReadCutKind(In: Reader): CutKind
	local Kind = CutKindOfIndex[ReadCharacter(In)]
	if Kind == nil then
		Malformed(UnknownCutKind)
	end
	return Kind
end

local function ReadCutName(In: Reader, Epoch: number, WindowUnit: number): CutName
	local Entry: CutName = {
		Kind = ReadCutKind(In),
		WindowSeconds = ReadWindow(In, WindowUnit),
		Name = ReadName(In),
		Stamp = ReadRoomStamp(In, Epoch),
	}
	Entry.Fingerprint = ReadNameFingerprint(In, Entry.Name)
	return Entry
end

local function FillScratches(Left: Name, Right: Name)
	LeftScratch.Cursor = 0
	RightScratch.Cursor = 0
	WriteName(LeftScratch, Left)
	WriteName(RightScratch, Right)
end

local function NameBefore(Left: Name, Right: Name): boolean
	FillScratches(Left, Right)
	return WrittenBefore(LeftScratch, RightScratch)
end

local function PartBefore(Left: number?, Right: number?): boolean
	if Left == nil then
		return Right ~= nil
	end
	return Right ~= nil and Left < Right
end

local function NamePartBefore(LeftName: Name, LeftPart: number?, RightName: Name, RightPart: number?): boolean
	FillScratches(LeftName, RightName)
	if WrittenBefore(LeftScratch, RightScratch) then
		return true
	end
	if WrittenBefore(RightScratch, LeftScratch) then
		return false
	end
	return PartBefore(LeftPart, RightPart)
end

local function StampThenName(LeftStamp: number, LeftName: Name, RightStamp: number, RightName: Name): boolean
	if LeftStamp ~= RightStamp then
		return LeftStamp < RightStamp
	end
	return NameBefore(LeftName, RightName)
end

local function StampNamePartBefore(
	LeftStamp: number,
	LeftName: Name,
	LeftPart: number?,
	RightStamp: number,
	RightName: Name,
	RightPart: number?
): boolean
	if LeftStamp ~= RightStamp then
		return LeftStamp < RightStamp
	end
	return NamePartBefore(LeftName, LeftPart, RightName, RightPart)
end

local function NamedEntryBefore(Left: NamedEntry, Right: NamedEntry): boolean
	local LeftName, RightName = Left.Name, Right.Name
	return StampNamePartBefore(Left.Stamp, LeftName.Name, LeftName.Part, Right.Stamp, RightName.Name, RightName.Part)
end

local function TimedBefore(Left: TimedItem, Right: TimedItem): boolean
	if Left.Kind == "Writer" then
		if Right.Kind == "Writer" then
			return Left.WriterId < Right.WriterId
		end
		return true
	end
	if Right.Kind == "Writer" then
		return false
	end
	return NamedEntryBefore(Left, Right)
end

local function CutNameBefore(Left: CutName, Right: CutName): boolean
	return StampThenName(Left.Stamp, Left.Name, Right.Stamp, Right.Name)
end

return {
	WriteNameFingerprint = WriteNameFingerprint,
	ReadNameFingerprint = ReadNameFingerprint,
	WriteRoomStamp = WriteRoomStamp,
	ReadRoomStamp = ReadRoomStamp,
	WriteStoredName = WriteStoredName,
	ReadStoredName = ReadStoredName,
	WriteWriterEntry = WriteWriterEntry,
	ReadWriterEntry = ReadWriterEntry,
	WriteNamedEntry = WriteNamedEntry,
	ReadNamedEntry = ReadNamedEntry,
	WriteTimedItem = WriteTimedItem,
	ReadTimedItem = ReadTimedItem,
	ReadUntimedEntry = ReadUntimedEntry,
	CutKindIndex = CutKindIndex,
	CutKindOfIndex = CutKindOfIndex,
	ReadCutKind = ReadCutKind,
	WriteCutName = WriteCutName,
	ReadCutName = ReadCutName,
	NameBefore = NameBefore,
	StampThenName = StampThenName,
	StampNamePartBefore = StampNamePartBefore,
	TimedBefore = TimedBefore,
	NamedEntryBefore = NamedEntryBefore,
	CutNameBefore = CutNameBefore,
	FateBefore = FateBefore,
}
