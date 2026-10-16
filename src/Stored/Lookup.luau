--!strict
--!optimize 2

--[=[
	Lookup: what a key's book already holds of an op, the lookups of rules J.1 and J.2 of the record sheet's
	section 9.

	A name is found whatever the entry's fingerprint, and LookupName says Spent when the fingerprints
	differ. A sub name matches only its own part; a plain stored name never matches one. Nothing here
	changes a run. HeldOfAsked is what DidApply reads of a game's name (Answers.md 5.7) under any part (a take's
	legs, Chosen 2.4): took if a pinned record (transaction sheet 3.3), a cut name in K or a timed entry took, else a
	standing mark's, else a timed entry's fate.

	Return type: A plain table of functions.
	Example usage:
		local Entry = Lookup.FindWriterEntry(StoredBook, WriterId)
--]=]

local Book = require("./Book")
local Entries = require("./Entries")
local Fates = require("./Items/Fates")
local JudgingRun = require("../Judging/Run")
local JudgingShapes = require("../Judging/Shapes")
local Names = require("../Encoding/Names")
local Timed = require("./Items/Timed")
local Work = require("./Items/Work")

type Fate = Fates.Fate
type OpName = Names.OpName
type Name = Names.Name
type NamedEntry = Timed.NamedEntry
type WriterEntry = Timed.WriterEntry
type Run = JudgingRun.Run
type Report = JudgingShapes.Report
type Book = Book.Book
type NameWithPart = Names.NameWithPart
type MarkOpening = Work.MarkOpening

local FingerprintOf = Entries.FingerprintOf

local NoPart: number? = nil

local function IsSameBaseName(Left: Name, Right: NameWithPart): boolean
	if Left.Kind == "Game" then
		return Right.Kind == "Game" and Left.Text == Right.Text
	end
	return Right.Kind == "Drawn" and Left.Server == Right.Server and Left.Counter == Right.Counter
end

local function IsSamePart(Left: number?, Right: number?): boolean
	return Left == Right
end

local function IsSameName(Left: Name, Right: NameWithPart): boolean
	return IsSamePart(NoPart, Right.Part) and IsSameBaseName(Left, Right)
end

local function IsOpeningOf(Opening: MarkOpening, Name: NameWithPart): boolean
	return IsSamePart(Opening.Part, Name.Part) and IsSameBaseName(Opening.Name, Name)
end

local function IsSameOp(Held: OpName, Name: OpName): boolean
	return IsSamePart(Held.Part, Name.Part)
		and IsSameBaseName(Entries.PlainName(Held), Name)
		and FingerprintOf(Held) == FingerprintOf(Name)
end

local function FindWriterEntry(StoredBook: Book, WriterId: number?): WriterEntry?
	for _, Item in StoredBook.Timed do
		if Item.Kind == "Writer" and Item.WriterId == WriterId then
			return Item
		end
	end
	return nil
end

local function EntryHolds(Entry: NamedEntry, Name: NameWithPart): boolean
	return IsSamePart(Entry.Name.Part, Name.Part) and IsSameBaseName(Entry.Name.Name, Name)
end

local function FindTimedEntry(StoredBook: Book, Name: NameWithPart): NamedEntry?
	for _, Item in StoredBook.Timed do
		if Item.Kind == "Named" and EntryHolds(Item, Name) then
			return Item
		end
	end
	return nil
end

local function FindUntimedEntry(StoredBook: Book, Name: NameWithPart): NamedEntry?
	for _, Entry in StoredBook.Untimed do
		if EntryHolds(Entry, Name) then
			return Entry
		end
	end
	return nil
end

local function HasUntimedOrCutName(StoredBook: Book, Name: NameWithPart): boolean
	if FindUntimedEntry(StoredBook, Name) ~= nil then
		return true
	end
	for _, Cut in StoredBook.CutNames do
		if IsSameName(Cut.Name, Name) then
			return true
		end
	end
	return false
end

local function IsTookFate(Fate: Fate): boolean
	return Fate.Kind == "Took" or Fate.Kind == "TookWith"
end

local function TookReport(): Report
	return { Kind = "Fated", Fate = { Kind = "Took" }, State = nil }
end

local function WorkOfAsked(StoredBook: Book, Name: Name): Report?
	local Held: Report? = nil
	for _, Item in StoredBook.Work do
		if not IsSameBaseName(Item.Opening.Name, Name) then
			continue
		end
		if Item.Kind == "Pinned" then
			return TookReport()
		end
		local Marks: { Work.Mark } = { Item }
		Held = { Kind = "Marks" :: "Marks", Marks = Marks }
	end
	return Held
end

local function TimedOfAsked(StoredBook: Book, Name: Name): NamedEntry?
	local Found: NamedEntry? = nil
	for _, Item in StoredBook.Timed do
		if Item.Kind ~= "Named" or not IsSameBaseName(Item.Name.Name, Name) then
			continue
		end
		if IsTookFate(Item.Fate) then
			return Item
		end
		Found = Item
	end
	return Found
end

local function IsCutNameOf(StoredBook: Book, Name: Name): boolean
	for _, Cut in StoredBook.CutNames do
		if IsSameBaseName(Cut.Name, Name) then
			return true
		end
	end
	return false
end

local function HeldOfAsked(StoredBook: Book, Name: Name): Report?
	local Work = WorkOfAsked(StoredBook, Name)
	if (Work ~= nil and Work.Kind == "Fated") or IsCutNameOf(StoredBook, Name) then
		return TookReport()
	end
	local Entry = TimedOfAsked(StoredBook, Name)
	if Entry ~= nil and IsTookFate(Entry.Fate) then
		return { Kind = "Fated", Fate = Entry.Fate, State = nil }
	end
	if Work ~= nil then
		return Work
	end
	if Entry ~= nil then
		return { Kind = "Fated", Fate = Entry.Fate, State = nil }
	end
	return nil
end

local function UntimedTookOfAsked(StoredBook: Book, Name: Name): boolean
	for _, Entry in StoredBook.Untimed do
		if IsSameBaseName(Entry.Name.Name, Name) and IsTookFate(Entry.Fate) then
			return true
		end
	end
	return false
end

local function LookupWriter(Run: Run, Sequence: number): Report?
	local Entry = FindWriterEntry(Run.Book, Run.Request.WriterId)
	if Entry == nil or Sequence > Entry.Highest then
		return nil
	end
	for _, Fate in Entry.Fates do
		if Fate.Sequence ~= Sequence then
			continue
		end
		if Fate.Kind == "Cut" then
			return { Kind = "Cut" }
		end
		if Fate.Kind == "Refused" then
			return { Kind = "Fated", Fate = { Kind = "Refused" }, State = nil }
		end
		return { Kind = "Fated", Fate = { Kind = "Full" }, State = nil }
	end
	return { Kind = "Fated", Fate = { Kind = "Took" }, State = nil }
end

local function SpentIfFingerprintsDiffer(Stored: number?, Name: OpName, Agreed: Report): Report
	if Stored ~= FingerprintOf(Name) then
		return { Kind = "Spent" }
	end
	return Agreed
end

local function LookupName(Run: Run, Name: OpName): Report?
	for _, Item in Run.Book.Timed do
		if Item.Kind == "Named" and EntryHolds(Item, Name) then
			local Stored: Report = { Kind = "Fated", Fate = Item.Fate, State = nil }
			return SpentIfFingerprintsDiffer(Item.Fingerprint, Name, Stored)
		end
	end
	for _, Cut in Run.Book.CutNames do
		if IsSameName(Cut.Name, Name) then
			local Took: Report = { Kind = "Fated", Fate = { Kind = "Took" }, State = nil }
			return SpentIfFingerprintsDiffer(Cut.Fingerprint, Name, Took)
		end
	end
	for _, Entry in Run.Book.Untimed do
		if EntryHolds(Entry, Name) then
			local Stored: Report = { Kind = "Fated", Fate = Entry.Fate, State = nil }
			return SpentIfFingerprintsDiffer(Entry.Fingerprint, Name, Stored)
		end
	end
	for _, Mark in Run.Book.Work do
		if IsOpeningOf(Mark.Opening, Name) then
			local MarksReport: Report = { Kind = "Marks", Marks = { Mark } }
			return SpentIfFingerprintsDiffer(Mark.Opening.Fingerprint, Name, MarksReport)
		end
	end
	return nil
end

return {
	IsSameName = IsSameName,
	IsOpeningOf = IsOpeningOf,
	IsSameOp = IsSameOp,
	FindWriterEntry = FindWriterEntry,
	EntryHolds = EntryHolds,
	FindTimedEntry = FindTimedEntry,
	FindUntimedEntry = FindUntimedEntry,
	HasUntimedOrCutName = HasUntimedOrCutName,
	HeldOfAsked = HeldOfAsked,
	UntimedTookOfAsked = UntimedTookOfAsked,
	LookupWriter = LookupWriter,
	LookupName = LookupName,
}
