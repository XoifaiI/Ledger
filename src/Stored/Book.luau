--!strict
--!optimize 2

--[=[
	Book: the field b of a game key's value (spec/protocols/record/Format.md 6): its fixed fields, flags, room counts
	and rooms T, K, U, P, L and S.

	The caller sorts each room, sets the epoch and gives the WindowUnit its windows are stored in. A reader throws
	through Format.Malformed, or NewerFormat on a newer format's version or flags; DecodeBook gives nil.

	Return type: A plain table of functions and the rooms, and the Book, Identity and Room types.
	Example usage:
		Book.EncodeBook({
			Format = 0,
			Level = 0,
			Floor = 0,
			Writes = 1,
			Cuts = 0,
			Epoch = 0,
			Horizon = 0,
			CutHorizon = 0,
			Timed = {},
			CutNames = {},
			Untimed = {},
			Work = {},
			Losses = { Events = {}, Returns = {} },
			Slots = {},
		}, Limits.WindowUnit) --> "AAAABAAAAAAAAAAAAAAAAAAAAAA"
--]=]

local Format = require("../Encoding/Format")
local Losses = require("./Items/Losses")
local Record = require("../Constants/Record")
local Seal = require("./Items/Seal")
local Timed = require("./Items/Timed")
local Work = require("./Items/Work")

type Writer = Format.Writer
type Reader = Format.Reader
type TimedItem = Timed.TimedItem
type NamedEntry = Timed.NamedEntry
type CutName = Timed.CutName
type Mark = Work.Mark
type Event = Losses.Event
type NamedReturn = Losses.NamedReturn
type FoldSlot = Losses.FoldSlot
type LossItems = Losses.LossItems
type Gate = Seal.Gate

export type Identity = {
	Server: number,
	Counter: number,
}

export type Book = {
	Format: number,
	Level: number,
	Floor: number,
	Writes: number,
	Cuts: number,
	Identity: Identity?,
	Gate: Gate?,
	Epoch: number,
	Horizon: number,
	CutHorizon: number,
	Timed: { TimedItem },
	CutNames: { CutName },
	Untimed: { NamedEntry },
	Work: { Mark },
	Losses: LossItems,
	Slots: { FoldSlot },
}

export type Room<Item> = {
	Write: (Out: Writer, Item: Item, Epoch: number, WindowUnit: number) -> (),
	Read: (In: Reader, Epoch: number, WindowUnit: number) -> Item,
	Before: (Left: Item, Right: Item) -> boolean,
}

type RoomCounts = {
	Timed: number,
	CutNames: number,
	Untimed: number,
	Work: number,
	Losses: number,
	Slots: number,
}

type BookRooms = {
	Timed: Room<TimedItem>,
	CutNames: Room<CutName>,
	Untimed: Room<NamedEntry>,
	Work: Room<Mark>,
	Events: Room<Event>,
	Returns: Room<NamedReturn>,
	Slots: Room<FoldSlot>,
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

local WriteTimedItem = Timed.WriteTimedItem
local WriteNamedEntry = Timed.WriteNamedEntry
local ReadTimedItem = Timed.ReadTimedItem
local ReadUntimedEntry = Timed.ReadUntimedEntry
local WriteCutName = Timed.WriteCutName
local ReadCutName = Timed.ReadCutName
local TimedBefore = Timed.TimedBefore
local NamedEntryBefore = Timed.NamedEntryBefore
local CutNameBefore = Timed.CutNameBefore

local WriteMark = Work.WriteMark
local ReadMark = Work.ReadMark
local MarkBefore = Work.MarkBefore

local LossCount = Losses.LossCount
local WriteLossRoom = Losses.WriteLossRoom
local ReadLossRoom = Losses.ReadLossRoom
local WriteFoldSlot = Losses.WriteFoldSlot
local ReadFoldSlot = Losses.ReadFoldSlot
local SlotBefore = Losses.SlotBefore

local WriteGate = Seal.WriteGate
local ReadGate = Seal.ReadGate

local BookVersion = Record.BookVersion
local IdentityFlag = Record.IdentityFlag
local GateFlag = Record.GateFlag
local BookFlagsMost = Record.BookFlagsMost
local EncodeStartBytes = Record.EncodeStartBytes

local ItemScratchBytes = math.max(Record.EventMax, Record.SlotMax)
local ItemScratch = NewWriter(ItemScratchBytes)

local UnknownBookVersion = "b starts with a version this format does not know"
local ItemsDescend = "items of one room descend by their order"
local ModuleName = "Book"
local WrongBookVersion = `{ModuleName}: a book is written at version {BookVersion}. The caller must give that one`

local NewerFormat = table.freeze({ Kind = "Newer" :: "Newer" })

local Rooms: BookRooms = {
	Timed = { Write = WriteTimedItem, Read = ReadTimedItem, Before = TimedBefore },
	CutNames = { Write = WriteCutName, Read = ReadCutName, Before = CutNameBefore },
	Untimed = { Write = WriteNamedEntry, Read = ReadUntimedEntry, Before = NamedEntryBefore },
	Work = { Write = WriteMark, Read = ReadMark, Before = MarkBefore },
	Events = { Write = Losses.WriteEvent, Read = Losses.ReadResetEvent, Before = Losses.EventBefore },
	Returns = {
		Write = Losses.WriteNamedReturn,
		Read = Losses.ReadNamedReturnWithCause,
		Before = Losses.ReturnBefore,
	},
	Slots = { Write = WriteFoldSlot, Read = ReadFoldSlot, Before = SlotBefore },
}

local function WriteRoom<Item>(Out: Writer, Items: { Item }, Room: Room<Item>, Epoch: number, WindowUnit: number)
	for _, Item in Items do
		Room.Write(Out, Item, Epoch, WindowUnit)
	end
end

local function ReadRoom<Item>(In: Reader, Count: number, Room: Room<Item>, Epoch: number, WindowUnit: number): { Item }
	local Items: { Item } = {}
	for Index = 1, Count do
		local Item = Room.Read(In, Epoch, WindowUnit)
		local Previous = Items[Index - 1]
		if Previous ~= nil and Room.Before(Item, Previous) then
			Malformed(ItemsDescend)
		end
		Items[Index] = Item
	end
	return Items
end

local function WriteFlags(Out: Writer, Book: Book)
	local Flags = 0
	if Book.Identity ~= nil then
		Flags += IdentityFlag
	end
	if Book.Gate ~= nil then
		Flags += GateFlag
	end
	WriteCharacter(Out, Flags)
end

local function WrittenByNewerLedger(): never
	error(NewerFormat)
end

local function IsNewerFormat(Problem: unknown): boolean
	return Problem == NewerFormat
end

local function ReadFlags(In: Reader): (boolean, boolean)
	local Flags = ReadCharacter(In)
	if Flags > BookFlagsMost then
		WrittenByNewerLedger()
	end
	return bit32.btest(Flags, IdentityFlag), bit32.btest(Flags, GateFlag)
end

local function ReadVersion(In: Reader): number
	local Version = ReadCharacter(In)
	if Version > BookVersion then
		WrittenByNewerLedger()
	end
	if Version ~= BookVersion then
		Malformed(UnknownBookVersion)
	end
	return Version
end

local function WriteIdentity(Out: Writer, Identity: Identity)
	WriteVarint(Out, Identity.Server)
	WriteVarint(Out, Identity.Counter)
end

local function ReadIdentity(In: Reader): Identity
	return { Server = ReadVarint(In), Counter = ReadVarint(In) }
end

local function WriteCounts(Out: Writer, Book: Book)
	WriteFixedNumber(Out, #Book.Timed)
	WriteFixedNumber(Out, #Book.CutNames)
	WriteFixedNumber(Out, #Book.Untimed)
	WriteFixedNumber(Out, #Book.Work)
	WriteFixedNumber(Out, LossCount(Book.Losses))
	WriteFixedNumber(Out, #Book.Slots)
end

local function ReadCounts(In: Reader): RoomCounts
	return {
		Timed = ReadFixedNumber(In),
		CutNames = ReadFixedNumber(In),
		Untimed = ReadFixedNumber(In),
		Work = ReadFixedNumber(In),
		Losses = ReadFixedNumber(In),
		Slots = ReadFixedNumber(In),
	}
end

local function EncodeBook(Book: Book, WindowUnit: number): string
	if Book.Format ~= BookVersion then
		error(WrongBookVersion)
	end
	local Out = NewWriter(EncodeStartBytes)
	WriteCharacter(Out, Book.Format)
	WriteFlags(Out, Book)
	WriteVarint(Out, Book.Level)
	WriteVarint(Out, Book.Floor)
	WriteVarint(Out, Book.Writes)
	WriteVarint(Out, Book.Cuts)
	if Book.Identity ~= nil then
		WriteIdentity(Out, Book.Identity)
	end
	if Book.Gate ~= nil then
		WriteGate(Out, Book.Gate)
	end
	WriteVarint(Out, Book.Epoch)
	WriteVarint(Out, Book.Horizon)
	WriteVarint(Out, Book.CutHorizon)
	WriteCounts(Out, Book)
	WriteRoom(Out, Book.Timed, Rooms.Timed, Book.Epoch, WindowUnit)
	WriteRoom(Out, Book.CutNames, Rooms.CutNames, Book.Epoch, WindowUnit)
	WriteRoom(Out, Book.Untimed, Rooms.Untimed, Book.Epoch, WindowUnit)
	WriteRoom(Out, Book.Work, Rooms.Work, Book.Epoch, WindowUnit)
	WriteLossRoom(Out, Book.Losses, Book.Epoch)
	WriteRoom(Out, Book.Slots, Rooms.Slots, Book.Epoch, WindowUnit)
	return ToString(Out)
end

local function ReadBook(In: Reader, WindowUnit: number): Book
	local Version = ReadVersion(In)
	local HasIdentity, HasGate = ReadFlags(In)
	local Book = {
		Format = Version,
		Level = ReadVarint(In),
		Floor = ReadVarint(In),
		Writes = ReadVarint(In),
		Cuts = ReadVarint(In),
		Identity = if HasIdentity then ReadIdentity(In) else nil,
		Gate = if HasGate then ReadGate(In) else nil,
		Epoch = ReadVarint(In),
		Horizon = ReadVarint(In),
		CutHorizon = ReadVarint(In),
	}
	local Counts = ReadCounts(In)
	Book.Timed = ReadRoom(In, Counts.Timed, Rooms.Timed, Book.Epoch, WindowUnit)
	Book.CutNames = ReadRoom(In, Counts.CutNames, Rooms.CutNames, Book.Epoch, WindowUnit)
	Book.Untimed = ReadRoom(In, Counts.Untimed, Rooms.Untimed, Book.Epoch, WindowUnit)
	Book.Work = ReadRoom(In, Counts.Work, Rooms.Work, Book.Epoch, WindowUnit)
	Book.Losses = ReadLossRoom(In, Counts.Losses, Book.Epoch)
	Book.Slots = ReadRoom(In, Counts.Slots, Rooms.Slots, Book.Epoch, WindowUnit)
	return Book
end

local function ReadBookText(Text: string, WindowUnit: number): Book
	return ReadWhole(Text, function(In: Reader): Book
		return ReadBook(In, WindowUnit)
	end)
end

local function DecodeBook(Text: string, WindowUnit: number): Book?
	local Succeeded, Book = pcall(ReadBookText, Text, WindowUnit)
	if not Succeeded then
		return nil
	end
	return Book
end

local function ItemSize<Item>(Room: Room<Item>, Item: Item, Epoch: number, WindowUnit: number): number
	ItemScratch.Cursor = 0
	Room.Write(ItemScratch, Item, Epoch, WindowUnit)
	return ItemScratch.Cursor
end

return {
	EncodeBook = EncodeBook,
	DecodeBook = DecodeBook,
	ReadBookText = ReadBookText,
	IsNewerFormat = IsNewerFormat,
	ItemSize = ItemSize,
	Rooms = Rooms,
}
