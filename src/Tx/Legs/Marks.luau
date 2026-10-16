--!strict
--!optimize 2

--[=[
	Marks: this protocol's items in the room P of a working book, and what is written into T beside them:
	finding, counting, placing and removing them, and clean flags.

	A pinned record is in P but not a mark; the WorkItem functions take either. MarksOf and PinnedOf leave the
	fingerprint to the caller; IsOfUse and the Own lookups compare it.

	Return type: A plain table of functions.
	Example usage:
		if Marks.HasPlaceFor(Run, Mark) then
			Marks.PlaceWorkItem(Run, Mark)
		end
--]=]

local Balances = require("./Balances")
local Book = require("../../Stored/Book")
local Decide = require("../../Judging/Decide")
local Entries = require("../../Stored/Entries")
local Fates = require("../../Stored/Items/Fates")
local JudgingRun = require("../../Judging/Run")
local JudgingShapes = require("../../Judging/Shapes")
local Lookup = require("../../Stored/Lookup")
local Names = require("../../Encoding/Names")
local Post = require("../../Stored/Post")
local Record = require("../../Constants/Record")
local Rooms = require("../../Stored/Rooms")
local Shapes = require("../../Shapes")
local Timed = require("../../Stored/Items/Timed")
local Work = require("../../Stored/Items/Work")

type Fate = Fates.Fate
type Declaration = Balances.Declaration
type KeyReference = Names.KeyReference
type OpName = Names.OpName
type PathStep = Post.PathStep
type Limits = Shapes.Limits
type Report = JudgingShapes.Report
type Run = JudgingRun.Run
type SentOp = Shapes.SentOp
type Verdict = JudgingShapes.Verdict
type EscrowMark = Work.EscrowMark
type ExclusiveMark = Work.ExclusiveMark
type Mark = Work.Mark
type StandingMark = Work.StandingMark
type MarkOpening = Work.MarkOpening
type NamedEntry = Timed.NamedEntry
type PinnedRecord = Work.PinnedRecord
type Book = Book.Book

local IsOpeningOf = Lookup.IsOpeningOf
local EntryHolds = Lookup.EntryHolds
local FingerprintOf = Entries.FingerprintOf
local PlainName = Entries.PlainName
local NewEntry = Entries.NewEntry
local NewTimedEntry = Entries.NewTimedEntry
local RoomUse = Rooms.RoomUse
local EscrowMarksOf = Work.EscrowMarksOf

local MarkMax = Record.MarkMax

local WorkItemRoom = Book.Rooms.Work

local ModuleName = "Marks"
local NotInWork =
	`{ModuleName}: the item is not in the room P of the working book. The caller must give one it found there`
local NoFingerprint = `{ModuleName}: an opening of a game name has its fingerprint. The caller must give one that has`

local function MarksOf(Working: Book, Name: OpName): { Mark }
	local Found: { Mark } = {}
	for _, Item in Working.Work do
		if Item.Kind ~= "Pinned" and IsOpeningOf(Item.Opening, Name) then
			table.insert(Found, Item)
		end
	end
	return Found
end

local function PinnedOf(Working: Book, Name: OpName): PinnedRecord?
	for _, Item in Working.Work do
		if Item.Kind == "Pinned" and IsOpeningOf(Item.Opening, Name) then
			return Item
		end
	end
	return nil
end

local function IsOfUse(Item: Mark, Name: OpName): boolean
	return IsOpeningOf(Item.Opening, Name) and Item.Opening.Fingerprint == FingerprintOf(Name)
end

local function OwnMarkOf(Working: Book, Name: OpName): StandingMark?
	for _, Item in Working.Work do
		if Item.Kind ~= "Pinned" and IsOfUse(Item, Name) then
			return Item
		end
	end
	return nil
end

local function OwnPinnedOf(Working: Book, Name: OpName): PinnedRecord?
	for _, Item in Working.Work do
		if Item.Kind == "Pinned" and IsOfUse(Item, Name) then
			return Item
		end
	end
	return nil
end

local function MarksIn(Working: Book): { Mark }
	local Found: { Mark } = {}
	for _, Item in Working.Work do
		if Item.Kind ~= "Pinned" then
			table.insert(Found, Item)
		end
	end
	return Found
end

local function PinnedIn(Working: Book): { Mark }
	local Found: { Mark } = {}
	for _, Item in Working.Work do
		if Item.Kind == "Pinned" then
			table.insert(Found, Item)
		end
	end
	return Found
end

local function ExclusiveOf(Working: Book): ExclusiveMark?
	for _, Item in Working.Work do
		if Item.Kind == "Exclusive" then
			return Item
		end
	end
	return nil
end

local function HasExclusive(Working: Book): boolean
	return ExclusiveOf(Working) ~= nil
end

local function CountMarks(Working: Book): number
	local Count = 0
	for _, Item in Working.Work do
		if Item.Kind ~= "Pinned" then
			Count += 1
		end
	end
	return Count
end

local function CountPinned(Working: Book): number
	local Count = 0
	for _, Item in Working.Work do
		if Item.Kind == "Pinned" then
			Count += 1
		end
	end
	return Count
end

local function NewOpening(Name: OpName, Stamp: number, Attempt: number): MarkOpening
	return {
		Attempt = Attempt,
		Name = PlainName(Name),
		Part = Name.Part,
		Stamp = Stamp,
		Fingerprint = FingerprintOf(Name),
	}
end

local function NewEscrowMark(
	Opening: MarkOpening,
	Decider: KeyReference,
	Declaration: Declaration,
	Amount: unknown
): EscrowMark
	return {
		Kind = "Escrow",
		IsClean = true,
		Opening = Opening,
		Decider = Decider,
		Field = Declaration.Field,
		Amount = Balances.ToStored(Amount, Balances.ArithmeticOf(Declaration)),
		IsDebit = Declaration.Direction == Balances.Direction.Debit,
	}
end

local function NewExclusiveMark(Opening: MarkOpening, Decider: KeyReference, Slot: { PathStep }?): ExclusiveMark
	return { Kind = "Exclusive", IsClean = true, Opening = Opening, Decider = Decider, Slot = Slot }
end

local function NewPinnedRecord(Opening: MarkOpening, OtherLegs: { KeyReference }, DeciderValue: number?): PinnedRecord
	return {
		Kind = "Pinned",
		IsClean = false,
		Opening = Opening,
		OtherLegs = table.clone(OtherLegs),
		DeciderValue = DeciderValue,
	}
end

local function OpNameOf(Opening: MarkOpening): OpName
	local Name = Opening.Name
	if Name.Kind == "Drawn" then
		return { Kind = "Drawn", Server = Name.Server, Counter = Name.Counter, Part = Opening.Part }
	end
	local Fingerprint = Opening.Fingerprint
	if Fingerprint == nil then
		error(NoFingerprint)
	end
	return { Kind = "Game", Text = Name.Text, Fingerprint = Fingerprint, Part = Opening.Part }
end

local function MeasureEpoch(Run: Run, Item: Mark): number
	local Epoch = math.min(Run.Clock, Item.Opening.Stamp)
	if Run.Epoch ~= nil then
		Epoch = math.min(Epoch, Run.Epoch)
	end
	return Epoch
end

local function Lacking(Run: Run, Item: Mark): (number, number)
	local Limits = Run.Setup.Limits
	local Held: number
	local Cap: number
	if Item.Kind == "Pinned" then
		Held = CountPinned(Run.Book)
		Cap = Limits.OwedCap
	else
		Held = CountMarks(Run.Book)
		Cap = Limits.MarkCap
	end
	local Epoch = MeasureEpoch(Run, Item)
	local Used = RoomUse(Run.Book.Work, WorkItemRoom, Epoch, Limits)
		+ Limits.ItemSize(WorkItemRoom, Item, Epoch, Limits.WindowUnit)
	return math.max(Held + 1 - Cap, 0), math.max(Used - Limits.WorkRooms[Run.Kind], 0)
end

local function IsWithinMarkMax(Run: Run, Item: Mark): boolean
	local Limits = Run.Setup.Limits
	return Limits.ItemSize(WorkItemRoom, Item, MeasureEpoch(Run, Item), Limits.WindowUnit) <= MarkMax
end

local function HasPlaceFor(Run: Run, Item: Mark): boolean
	local Items, Bytes = Lacking(Run, Item)
	return Items == 0 and Bytes == 0
end

local function PlaceWorkItem(Run: Run, Item: Mark)
	table.insert(Run.Book.Work, Item)
	Run.Placed = Item
end

local function RemoveWorkItem(Run: Run, Item: Mark)
	local At = table.find(Run.Book.Work, Item)
	if At == nil then
		error(NotInWork)
	end
	table.remove(Run.Book.Work, At)
	if Item.Kind == "Exclusive" then
		Run.Post = nil
	end
end

local function IsEntryOfUse(Entry: NamedEntry, Name: OpName): boolean
	return EntryHolds(Entry, Name) and Entry.Fingerprint == FingerprintOf(Name)
end

local function RemoveEntriesOf(Run: Run, Holds: (Entry: NamedEntry) -> boolean)
	local TimedEntries = Run.Book.Timed
	for Index = #TimedEntries, 1, -1 do
		local Entry = TimedEntries[Index]
		if Entry.Kind == "Named" and Holds(Entry) then
			table.remove(TimedEntries, Index)
			Run.Written[Entry] = nil
		end
	end
end

local function RemoveNamed(Run: Run, Name: OpName)
	local function IsNamed(Entry: NamedEntry): boolean
		return EntryHolds(Entry, Name)
	end
	RemoveEntriesOf(Run, IsNamed)
end

local function OwnEntryOf(Working: Book, Name: OpName): NamedEntry?
	for _, Item in Working.Timed do
		if Item.Kind == "Named" and IsEntryOfUse(Item, Name) then
			return Item
		end
	end
	return nil
end

local function HasOtherEntry(Working: Book, Name: OpName): boolean
	for _, Item in Working.Timed do
		if Item.Kind == "Named" and EntryHolds(Item, Name) and not IsEntryOfUse(Item, Name) then
			return true
		end
	end
	return false
end

local function IsForgotten(Working: Book, Name: OpName, Stamp: number): boolean
	if Stamp > Working.Horizon then
		return false
	end
	for _, Item in Working.Timed do
		if Item.Kind == "Named" and EntryHolds(Item, Name) then
			return false
		end
	end
	for _, Item in Working.Work do
		if IsOpeningOf(Item.Opening, Name) then
			return false
		end
	end
	return not Lookup.HasUntimedOrCutName(Working, Name)
end

local function PutEntry(Run: Run, Name: OpName, Entry: NamedEntry)
	local function IsOwnEntry(Held: NamedEntry): boolean
		return IsEntryOfUse(Held, Name)
	end
	RemoveEntriesOf(Run, IsOwnEntry)
	table.insert(Run.Book.Timed, Entry)
	Run.Written[Entry] = true
end

local function WriteFate(Run: Run, OpKind: string, Name: OpName, Stamp: number, Fate: Fate)
	PutEntry(Run, Name, NewTimedEntry(Run.Setup.Limits, OpKind, Name, Stamp, Fate))
end

local function WriteEndFate(Run: Run, Name: OpName, Stamp: number, Fate: Fate)
	local Replaced = OwnEntryOf(Run.Book, Name)
	local Limits = Run.Setup.Limits
	local Window = if Replaced ~= nil then Replaced.WindowSeconds else Limits.MintedWindow
	PutEntry(Run, Name, NewEntry(Name, Stamp, Fate, Window, Limits.WindowUnit))
end

local function WriteRefusal(Run: Run, Op: SentOp, Name: OpName, Fate: Fate): Report
	WriteFate(Run, Op.OpKind, Name, Op.Stamp, Fate)
	table.insert(Run.Decided, Op)
	return { Kind = "Refused", Fate = Fate, State = Run.State }
end

local function RefuseOrStop(Run: Run, Op: SentOp, Name: OpName, Verdict: Verdict): Report
	local Judged = Decide.JudgedOf(Verdict)
	local Stopping = Decide.StopOf(Judged)
	if Stopping ~= nil then
		return Stopping
	end
	return WriteRefusal(Run, Op, Name, Decide.FateOf(Judged))
end

local function BlockedReport(Blockers: { Mark }, Limits: Limits): Report
	local Listed: { Mark } = {}
	for Index = 1, math.min(#Blockers, Limits.MarkCap) do
		table.insert(Listed, Blockers[Index])
	end
	return { Kind = "Blocked", Marks = Listed }
end

local function NoRoomReport(Run: Run, Item: Mark): Report
	local Items, Bytes = Lacking(Run, Item)
	return { Kind = "NoRoom", Marks = table.clone(Run.Book.Work), Short = { Items = Items, Bytes = Bytes } }
end

local function ClearCleanFlags(Working: Book, Placed: Mark?)
	for _, Item in Working.Work do
		if Item.Kind ~= "Pinned" and Item ~= Placed then
			Item.IsClean = false
		end
	end
end

return {
	MarksOf = MarksOf,
	PinnedOf = PinnedOf,
	IsOfUse = IsOfUse,
	OwnMarkOf = OwnMarkOf,
	OwnPinnedOf = OwnPinnedOf,
	MarksIn = MarksIn,
	PinnedIn = PinnedIn,
	ExclusiveOf = ExclusiveOf,
	HasExclusive = HasExclusive,
	EscrowMarksOf = EscrowMarksOf,
	CountMarks = CountMarks,
	CountPinned = CountPinned,
	NewOpening = NewOpening,
	NewEscrowMark = NewEscrowMark,
	NewExclusiveMark = NewExclusiveMark,
	NewPinnedRecord = NewPinnedRecord,
	OpNameOf = OpNameOf,
	IsWithinMarkMax = IsWithinMarkMax,
	HasPlaceFor = HasPlaceFor,
	PlaceWorkItem = PlaceWorkItem,
	RemoveWorkItem = RemoveWorkItem,
	RemoveNamed = RemoveNamed,
	OwnEntryOf = OwnEntryOf,
	HasOtherEntry = HasOtherEntry,
	IsForgotten = IsForgotten,
	WriteFate = WriteFate,
	WriteEndFate = WriteEndFate,
	WriteRefusal = WriteRefusal,
	RefuseOrStop = RefuseOrStop,
	BlockedReport = BlockedReport,
	NoRoomReport = NoRoomReport,
	ClearCleanFlags = ClearCleanFlags,
}
