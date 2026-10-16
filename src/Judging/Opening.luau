--!strict
--!optimize 2

--[=[
	Opening: what a write finds on its key (record sheet 9, K.1, K.2, G.1, G.2): the stored value, the key opened or
	the stopping report, and the guards of a worn out key or overdue work.

	Only an "absent" or "any" op creates. A ProveGone or seal stamp runs only this step (TX-PROVEGONE). G.2 skips end
	path writes.

	Return type: A plain table with OpenKey, GuardReport and NewBook, and the Opened type.
	Example usage:
		local Opened = Opening.OpenKey(Stored, Request, Setup, Closure, Clock)
--]=]

local Book = require("../Stored/Book")
local CutShapes = require("../Cuts/Shapes")
local Decider = require("../Tx/Legs/Decider")
local Ends = require("../Tx/Legs/Ends")
local JudgingShapes = require("./Shapes")
local Record = require("../Constants/Record")
local Seal = require("../Stored/Items/Seal")
local SealedKey = require("../Cuts/Rules/SealedKey")
local Shapes = require("../Shapes")
local TxShapes = require("../Tx/Shapes")
local Value = require("../Stored/Value")
local Work = require("../Stored/Items/Work")

type Identity = Book.Identity
type End = TxShapes.End
type Kept = Value.Kept
type Decoded = Value.Decoded
type Mark = Work.Mark
type Seal = Seal.Seal
type Limits = Shapes.Limits
type Setup = Shapes.Setup
type Incarnation = Shapes.Incarnation
type Closure = JudgingShapes.Closure
type Request = Shapes.Request
type SealStampRequest = CutShapes.SealStampRequest
type SentOp = Shapes.SentOp
type Report = JudgingShapes.Report
type NoteWarning = JudgingShapes.NoteWarning
type Book = Book.Book

export type Opened =
	{ read Kind: "Open", read Key: Kept, read IsMade: boolean, read WarningsIfLanded: { NoteWarning } }
	| { read Kind: "Shut", read Report: Report }
	| { read Kind: "ShutEach", read Reports: { Report }, read EndReports: { Report } }
	| { read Kind: "Seal", read Seal: Seal, read Report: Report }

type Fields = { [unknown]: unknown }

local CountsMax = Record.VarintLimit - 1

local NoEnds: { End } = {}
table.freeze(NoEnds)

local function NewBook(Setup: Setup, Identity: Identity?): Book
	local Build = Setup.Build
	return {
		Format = Record.BookVersion,
		Level = Build.MigrationCount,
		Floor = Build.BreakingIndex,
		Writes = 0,
		Cuts = 0,
		Identity = Identity,
		Gate = nil,
		Epoch = 0,
		Horizon = 0,
		CutHorizon = 0,
		Timed = {},
		CutNames = {},
		Untimed = {},
		Work = {},
		Losses = { Events = {}, Returns = {} },
		Slots = {},
	}
end

local function IsOfMadeKey(Tag: Incarnation): boolean
	return Tag.Kind == "Known" or Tag.Kind == "Legacy"
end

local function CreatingOp(Request: Request, Closure: Closure, Clock: number, Limits: Limits): SentOp?
	if Request.Kind ~= "Update" or #Request.Ops == 0 then
		return nil
	end
	if Closure.Wrote or Request.MustExist then
		return nil
	end
	local First = Request.Ops[1]
	if IsOfMadeKey(First.Incarnation) then
		return nil
	end
	if First.Form.Kind == "Commit" and not Decider.CommitMayCreate(First, Clock, Limits) then
		return nil
	end
	return First
end

local function Create(Setup: Setup, Creator: SentOp): Opened
	local Identity: Identity? = nil
	local Warnings: { NoteWarning } = {}
	local Incarnation = Creator.Incarnation
	if Incarnation.Kind == "Absent" then
		Identity = Incarnation.Fresh
		if not Creator.IsClean then
			local Warning: NoteWarning = { Kind = "CreatedAfterErase" }
			table.insert(Warnings, Warning)
		end
	end
	local Made: Kept = {
		Kind = "Kept",
		State = Value.CopyDefault(Setup.Build.Default),
		Book = NewBook(Setup, Identity),
		Post = nil,
		Given = nil,
	}
	return { Kind = "Open", Key = Made, IsMade = true, WarningsIfLanded = Warnings }
end

local function MeetSeal(Sealed: Seal, Request: Request, Creator: SentOp?, Setup: Setup, Clock: number): Opened
	local IsLeftOver = Seal.IsLeftOver(Sealed, Clock, Setup.Limits.SealAge)
	if Request.Kind == "Update" then
		local Own = SealedKey.OwnSealReports(Sealed, Request, IsLeftOver)
		if Own ~= nil then
			local Missing = SealedKey.MissingWithSeal(Sealed, IsLeftOver)
			return { Kind = "ShutEach", Reports = Own, EndReports = table.create(#Request.Ends, Missing) }
		end
	end
	if IsLeftOver and Creator ~= nil then
		return Create(Setup, Creator)
	end
	return { Kind = "Shut", Report = SealedKey.MissingWithSeal(Sealed, IsLeftOver) }
end

local function MeetNothing(Creator: SentOp?, Setup: Setup): Opened
	if Creator == nil then
		local Missing: Report = { Kind = "Missing", Identity = nil, Seal = nil, IsLeftOver = false, IsLegacy = false }
		return { Kind = "Shut", Report = Missing }
	end
	return Create(Setup, Creator)
end

local function DecodeStored(Stored: unknown, Setup: Setup): Decoded?
	if Stored == nil then
		return nil
	end
	return Value.DecodeStored(Stored, Setup.Build, Setup.Limits.WindowUnit)
end

local function OpenToProve(Held: Decoded?, Clock: number, Limits: Limits): Opened
	local Proof, Report = Ends.ProveGone(Held, Clock, Limits)
	if Proof == nil then
		return { Kind = "Shut", Report = Report }
	end
	return { Kind = "Seal", Seal = Proof, Report = Report }
end

local function OpenToStamp(Held: Decoded?, Stamp: SealStampRequest, Clock: number, Limits: Limits): Opened
	local Stamped, Report = SealedKey.OpenStamp(Held, Stamp, Clock, Limits)
	if Stamped == nil then
		return { Kind = "Shut", Report = Report }
	end
	return { Kind = "Seal", Seal = Stamped, Report = Report }
end

local function OpenKey(Stored: unknown, Request: Request, Setup: Setup, Closure: Closure, Clock: number): Opened
	local Held = DecodeStored(Stored, Setup)
	if Request.Kind == "ProveGone" then
		return OpenToProve(Held, Clock, Setup.Limits)
	end
	if Request.Kind == "SealStamp" then
		return OpenToStamp(Held, Request, Clock, Setup.Limits)
	end
	local Creator = CreatingOp(Request, Closure, Clock, Setup.Limits)
	if Held == nil then
		return MeetNothing(Creator, Setup)
	end
	if Held.Kind == "Unreadable" then
		local Unreadable: Report = { Kind = "Unreadable", Cause = Held.Cause }
		return { Kind = "Shut", Report = Unreadable }
	end
	if Held.Kind == "Kept" then
		return { Kind = "Open", Key = Held, IsMade = false, WarningsIfLanded = {} }
	end
	return MeetSeal(Held.Seal, Request, Creator, Setup, Clock)
end

local function EndsOf(Request: Request): { End }
	if Request.Kind == "Update" then
		return Request.Ends
	end
	return NoEnds
end

local function OverdueMarks(Working: Book, Carried: { End }, Clock: number, Limits: Limits): { Mark }
	local Overdue: { Mark } = {}
	for _, Mark in Working.Work do
		if Clock - Mark.Opening.Stamp >= Limits.Ceiling and not Ends.EndsMark(Carried, Mark) then
			table.insert(Overdue, Mark)
		end
	end
	return Overdue
end

local function IsEndPathWrite(Request: Request): boolean
	return Request.Kind == "Update" and #Request.Ends > 0 and #Request.Ops == 0
end

local function GuardReport(Working: Book, Request: Request, Clock: number, Limits: Limits): Report?
	if Working.Writes >= CountsMax or Working.Cuts >= CountsMax then
		return { Kind = "Worn" }
	end
	if IsEndPathWrite(Request) then
		return nil
	end
	local Overdue = OverdueMarks(Working, EndsOf(Request), Clock, Limits)
	if #Overdue > 0 then
		return { Kind = "Overdue", Marks = Overdue }
	end
	return nil
end

return {
	OpenKey = OpenKey,
	GuardReport = GuardReport,
	NewBook = NewBook,
}
