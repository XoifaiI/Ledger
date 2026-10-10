--!strict
--!optimize 2

--[=[
	Cut: rule 9 of a cut op (cuts sheet 4.9, 5.1). A reset names its money, folds L, replaces the state, keeps its name
	in K; an erase becomes a seal holding the namings. An unusable clock is Undecided; a rejected balance is Unreadable
	(Balance), an unwritable naming (Amounts). A reset takes "r" only under its own gate (Format 5).

	Return type: A plain table with CutKey.
	Example usage:
		local Report = Cut.CutKey(Run, Op, Form)
--]=]

local Balances = require("../../Tx/Legs/Balances")
local Book = require("../../Stored/Book")
local CutShapes = require("../Shapes")
local Entries = require("../../Stored/Entries")
local Fold = require("./Fold")
local Format = require("../../Encoding/Format")
local Judge = require("../../Judging/Judge")
local JudgingRun = require("../../Judging/Run")
local JudgingShapes = require("../../Judging/Shapes")
local Lookup = require("../../Stored/Lookup")
local Losses = require("../../Stored/Items/Losses")
local Rooms = require("../../Stored/Rooms")
local Seal = require("../../Stored/Items/Seal")
local Shapes = require("../../Shapes")
local Timed = require("../../Stored/Items/Timed")
local Value = require("../../Stored/Value")

type Fields = Value.Fields
type Event = Losses.Event
type FieldAmount = Losses.FieldAmount
type LossRecords = Losses.LossRecords
type Seal = Seal.Seal
type CutName = Timed.CutName
type CutForm = CutShapes.CutForm
type Build = Shapes.Build
type NoteWarning = JudgingShapes.NoteWarning
type Report = JudgingShapes.Report
type Run = JudgingRun.Run
type SentOp = Shapes.SentOp

local EventRoom = Book.Rooms.Events
local ReturnRoom = Book.Rooms.Returns
local SlotRoom = Book.Rooms.Slots

local FingerprintOf = Entries.FingerprintOf
local PlainName = Entries.PlainName
local IsZero = Balances.IsZero
local ReadBalance = Balances.ReadBalance
local SignedStoredOf = Balances.SignedStoredOf
local IsStorableAmount = Balances.IsStorableAmount
local RoundWindow = Format.RoundWindow
local IsClockUsable = Judge.IsClockUsable
local IsSameName = Lookup.IsSameName
local CopyDefault = Value.CopyDefault

local function NoteUnnamedBalance(Run: Run, Field: string)
	local Warning: NoteWarning = { Kind = "UnnamedBalance", Field = Field }
	table.insert(Run.Warnings, Warning)
end

local function NameLosses(Run: Run): { FieldAmount } | "Balance"
	local State = Run.State
	local Build = Run.Setup.Build
	local Declared: { string } = {}
	for Field in Build.Balances do
		table.insert(Declared, Field)
	end
	table.sort(Declared)
	local Named: { FieldAmount } = {}
	for _, Field in Declared do
		local Arithmetic = Build.Balances[Field]
		local Amount = ReadBalance(State, Field, Arithmetic)
		if Amount == nil then
			NoteUnnamedBalance(Run, Field)
			return "Balance"
		end
		if IsZero(Arithmetic, Amount) then
			continue
		end
		table.insert(Named, { Field = Field, Amount = SignedStoredOf(Amount, Arithmetic) })
	end
	return Named
end

local function NewEvent(Form: CutForm, Clock: number, Fields: { FieldAmount }): Event
	return {
		Cause = Form.CutKind,
		Name = PlainName(Form.Name),
		Stamp = Clock,
		Fields = Fields,
		Fingerprint = FingerprintOf(Form.Name),
	}
end

local function IsEventStorable(Event: Event): boolean
	for _, Entry in Event.Fields do
		if not IsStorableAmount(Entry.Amount) then
			return false
		end
	end
	return true
end

local function EventOf(Run: Run, Form: CutForm): Event | "Balance" | "Amounts" | nil
	local Named = NameLosses(Run)
	if Named == "Balance" then
		return Named
	end
	if #Named == 0 then
		return nil
	end
	local Event = NewEvent(Form, Run.Clock, Named)
	if not IsEventStorable(Event) then
		return "Amounts"
	end
	return Event
end

local function CutNameOf(Run: Run, Op: SentOp, Form: CutForm): CutName
	local Limits = Run.Setup.Limits
	return {
		Kind = Form.CutKind,
		WindowSeconds = RoundWindow(Limits.CutWindow, Limits.WindowUnit),
		Name = PlainName(Form.Name),
		Stamp = Op.Stamp,
		Fingerprint = FingerprintOf(Form.Name),
	}
end

local function IsOwnGate(Run: Run, Form: CutForm): boolean
	local Held = Run.Book.Gate
	return Held ~= nil and IsSameName(Held.Name, Form.Name)
end

local function ResetState(Run: Run, Form: CutForm): Fields
	if Form.Given ~= nil then
		return Form.Given
	end
	local StoredGiven = Run.Given
	if StoredGiven ~= nil and IsOwnGate(Run, Form) then
		return StoredGiven
	end
	return CopyDefault(Run.Setup.Build.Default)
end

local function ApplyReset(Run: Run, Op: SentOp, Form: CutForm): Report
	local Limits = Run.Setup.Limits
	local Event = EventOf(Run, Form)
	if type(Event) == "string" then
		return { Kind = "Unreadable", Cause = Event }
	end
	if Event ~= nil and not IsClockUsable(Run.Clock, Limits) then
		return { Kind = "Undecided" }
	end
	local CutNames = Run.Book.CutNames
	table.insert(CutNames, CutNameOf(Run, Op, Form))
	if Event ~= nil then
		local Folded = Fold.Fold(Run.Book, Event, Run.Clock, Run.Setup, Run.Kind)
		if Folded.Kind == "Wait" then
			table.remove(CutNames)
			return { Kind = "Wait", At = Folded.At }
		end
	end
	Rooms.FitCutNames(Run.Book, Limits)
	local Build = Run.Setup.Build
	Run.State = ResetState(Run, Form)
	Run.Book.Level = Build.MigrationCount
	Run.Book.Floor = Build.BreakingIndex
	Run.Book.Cuts += 1
	Run.Book.Gate = nil
	Run.Given = nil
	table.insert(Run.Decided, Op)
	return { Kind = "Took" }
end

local function SealOf(Run: Run, Op: SentOp, Form: CutForm, Erased: Event?): Seal
	local Working = Run.Book
	local Records: LossRecords = {
		Events = table.clone(Working.Losses.Events),
		Returns = table.clone(Working.Losses.Returns),
		Slots = table.clone(Working.Slots),
	}
	if Erased ~= nil then
		table.insert(Records.Events, Erased)
	end
	table.sort(Records.Events, EventRoom.Before)
	table.sort(Records.Returns, ReturnRoom.Before)
	table.sort(Records.Slots, SlotRoom.Before)
	return {
		Name = PlainName(Form.Name),
		Stamp = Op.Stamp,
		Sealer = Form.Sender,
		RemovalStamp = Run.Clock,
		Fingerprint = FingerprintOf(Form.Name),
		Records = Records,
	}
end

local function CutKey(Run: Run, Op: SentOp, Form: CutForm): Report
	if Form.CutKind == "Reset" then
		return ApplyReset(Run, Op, Form)
	end
	local Limits = Run.Setup.Limits
	local Erased = EventOf(Run, Form)
	if type(Erased) == "string" then
		return { Kind = "Unreadable", Cause = Erased }
	end
	if not IsClockUsable(Run.Clock, Limits) then
		return { Kind = "Undecided" }
	end
	Rooms.PruneLosses(Run.Book.Losses, Run.Clock, Limits)
	Rooms.PruneSlots(Run.Book.Slots, Run.Clock, Limits)
	local Sealed = SealOf(Run, Op, Form, Erased)
	Run.Sealed = Sealed
	table.insert(Run.Decided, Op)
	return { Kind = "Sealed", Seal = Sealed }
end

return {
	CutKey = CutKey,
}
