--!strict
--!optimize 2

--[=[
	Judge: one request's judgement (record sheet 9, J.0 to J.11): record ops and a Tx's Tent and Commit; a cut throws. A
	legacy tag matches only an id-less record (K.3).

	Blocked, Unreadable, Invalid, or a hold on an unusable clock (K.4) stops the request with no fate. A rejected
	balance, even stored, fails migration (J.9). The caller sets Run.Epoch first.

	Return type: A plain table with JudgeOps, StopWith, IsOtherIncarnation and IsClockUsable. Lookup finds what the key
	already holds (J.1, J.2).
	Example usage:
		Judge.JudgeOps(Run)
		local Report = Run.Reports[1]
--]=]

local Balances = require("../Tx/Legs/Balances")
local Book = require("../Stored/Book")
local Decide = require("./Decide")
local Decider = require("../Tx/Legs/Decider")
local Entries = require("../Stored/Entries")
local Fates = require("../Stored/Items/Fates")
local Guards = require("./Guards")
local Json = require("../Encoding/Json")
local JudgingRun = require("./Run")
local JudgingShapes = require("./Shapes")
local Lookup = require("../Stored/Lookup")
local Marks = require("../Tx/Legs/Marks")
local Names = require("../Encoding/Names")
local OpForms = require("./OpForms")
local OrderRule = require("../Tx/Legs/OrderRule")
local Rooms = require("../Stored/Rooms")
local Shapes = require("../Shapes")
local Tent = require("../Tx/Legs/Tent")
local TxShapes = require("../Tx/Shapes")
local View = require("../Reading/View")

type Fate = Fates.Fate
type TentForm = TxShapes.TentForm
type CommitForm = TxShapes.CommitForm
type OpName = Names.OpName
type GameOpName = Names.GameOpName
type Name = Names.Name
type WriterFateKind = Fates.WriterFateKind
type Limits = Shapes.Limits
type Run = JudgingRun.Run
type SentOp = Shapes.SentOp
type Report = JudgingShapes.Report
type NoteWarning = JudgingShapes.NoteWarning
type Incarnation = Shapes.Incarnation
type OpForm = Shapes.OpForm
type Book = Book.Book

type Judged = JudgingShapes.Judged

local HasSequence = OpForms.HasSequence
local SequenceOf = OpForms.SequenceOf
local NewTimedEntry = Entries.NewTimedEntry
local NewUntimedEntry = Entries.NewUntimedEntry

local UntimedRoom = Book.Rooms.Untimed

local ModuleName = "Judge"
local CutNotJudged = `{ModuleName}: a cut is judged by the cuts' cases. The caller must not give one to the record's`

local function StopWith(Run: Run, Report: Report): Report
	Run.IsStopped = true
	return Report
end

local function NameOf(Form: OpForm): OpName?
	if Form.Kind == "Timed" or Form.Kind == "Untimed" or Form.Kind == "Tent" or Form.Kind == "Commit" then
		return Form.Name
	end
	return nil
end

local function WriterFateKindOf(Fate: Fate): WriterFateKind?
	if Fate.Kind == "Refused" or Fate.Kind == "RefusedFor" then
		return "Refused"
	end
	if Fate.Kind == "Full" then
		return "Full"
	end
	return nil
end

local function IsOtherIncarnation(StoredBook: Book, Incarnation: Incarnation): boolean
	if Incarnation.Kind == "Any" then
		return false
	end
	local Identity = StoredBook.Identity
	if Incarnation.Kind == "Legacy" then
		return Identity ~= nil
	end
	if Identity == nil then
		return true
	end
	local Carried = if Incarnation.Kind == "Known" then Incarnation.Identity else Incarnation.Fresh
	return Carried.Server ~= Identity.Server or Carried.Counter ~= Identity.Counter
end

local function OtherIncarnationReport(StoredBook: Book): Report
	local Identity = StoredBook.Identity
	return { Kind = "Missing", Identity = Identity, Seal = nil, IsLeftOver = false, IsLegacy = Identity == nil }
end

local function IsClockUsable(Clock: number, Limits: Limits): boolean
	return Clock >= 1 and Clock <= Limits.StampMax
end

local function AddAlsoCutWarning(Run: Run, Name: OpName)
	local Gate = Run.Book.Gate
	if Gate ~= nil and Lookup.IsSameName(Gate.Name, Name) then
		local Warning: NoteWarning = { Kind = "AlsoCut", Name = Gate.Name }
		table.insert(Run.Warnings, Warning)
	end
end

local function IsForgotten(Run: Run, Op: SentOp): boolean
	local Form = Op.Form
	if Form.Kind == "Timed" then
		return Op.Stamp <= Run.Book.Horizon
	end
	if Form.Kind == "Tent" or Form.Kind == "Commit" then
		return Lookup.FindTimedEntry(Run.Book, Form.Name) == nil and Op.Stamp <= Run.Book.Horizon
	end
	if Form.Kind == "Minted" or Form.Kind == "Hopeful" then
		return Lookup.FindWriterEntry(Run.Book, Run.Request.WriterId) == nil and Op.Stamp <= Run.Book.Horizon
	end
	return false
end

local function IsBehind(Run: Run): boolean
	return Run.Book.Floor > Run.Setup.Build.BreakingIndex
end

local function IsAhead(Run: Run, Op: SentOp): boolean
	if Op.Form.Kind == "Untimed" then
		return false
	end
	return Op.Stamp > math.max(Run.Clock, Run.Book.Horizon) + Run.Setup.Limits.Ahead
end

local function IsViewCut(Run: Run, Op: SentOp): boolean
	local Form = Op.Form
	if Form.Kind ~= "Hopeful" then
		return false
	end
	return Form.ViewCuts ~= Run.Book.Cuts
end

local function IsFatesFull(Run: Run): boolean
	local Kept = 0
	local Entry = Lookup.FindWriterEntry(Run.Book, Run.Request.WriterId)
	if Entry ~= nil then
		for _, Fate in Entry.Fates do
			if Fate.Sequence > Run.Request.Acknowledged then
				Kept += 1
			end
		end
	end
	return Kept + #Run.NewFates >= Run.Setup.Limits.FatesMax
end

local function RoomEpoch(Run: Run): number
	local Epoch = Run.Clock
	if Run.Epoch ~= nil then
		Epoch = math.min(Epoch, Run.Epoch)
	end
	for _, Op in Run.Request.Ops do
		Epoch = math.min(Epoch, Op.Stamp)
	end
	return Epoch
end

local function HasUntimedRoom(Run: Run, Op: SentOp, Name: GameOpName, Epoch: number): boolean
	local Limits = Run.Setup.Limits
	local Entry = NewUntimedEntry(Limits, Op.OpKind, Name, Run.Clock, { Kind = "Took" })
	local Left = Rooms.UntimedRoomLeft(Run.Book, Epoch, Run.Kind, Limits)
	return Left >= Limits.ItemSize(UntimedRoom, Entry, Epoch, Limits.WindowUnit)
end

local function JudgeClockAndUntimedRoom(Run: Run, Op: SentOp, Name: GameOpName, Epoch: number): Report?
	if not IsClockUsable(Run.Clock, Run.Setup.Limits) then
		return StopWith(Run, { Kind = "Undecided" })
	end
	if not HasUntimedRoom(Run, Op, Name, Epoch) then
		return StopWith(Run, { Kind = "NoRoom", Marks = {} })
	end
	return nil
end

local function RunMigrations(Run: Run): boolean
	Run.MigrationsTried = true

	local Build = Run.Setup.Build
	local Limits = Run.Setup.Limits
	local State = Run.State
	for Index = Run.Book.Level + 1, Build.MigrationCount do
		local Outcome = Guards.RunMigration(Build.Migrations[Index].Run, State, Limits)
		if Outcome.Kind ~= "State" then
			return false
		end

		if Json.Size(Outcome.State) > Limits.StateCap then
			return false
		end

		State = Outcome.State
	end
	if Balances.HoldsInvalidBalance(State, Build.Balances) then
		return false
	end

	local Floor = View.MigratedFloor(Build, Run.Book.Level, Run.Book.Floor)
	Run.State = State
	Run.Book.Level = Build.MigrationCount
	Run.Book.Floor = Floor
	return true
end

local function IsMigrated(Run: Run): boolean
	local Build = Run.Setup.Build
	if Run.Book.Level >= Build.MigrationCount then
		return Build.MigrationCount == 0 or not Balances.HoldsInvalidBalance(Run.State, Build.Balances)
	end
	if Run.MigrationsTried then
		return false
	end
	return RunMigrations(Run)
end

local function DecideOp(Run: Run, Op: SentOp): Judged
	local Escrows = Marks.EscrowMarksOf(Run.Book.Work)
	local Verdict = Decide.DecideOnState(Run.Setup, Run.State, Op.OpKind, Op.Terms, Escrows, Run.Clock)
	if Verdict.Kind == "Took" or Verdict.Kind == "TookWith" then
		Run.State = Verdict.State
	end
	return Decide.JudgedOf(Verdict)
end

local function JudgeOneKey(Run: Run, Op: SentOp): Judged
	if not IsMigrated(Run) then
		return { Kind = "Refused" }
	end
	return DecideOp(Run, Op)
end

local function JudgeBesideMarks(Run: Run, Op: SentOp): Report?
	local MigrationBlock = OrderRule.MigrationBlocks(Run)
	if MigrationBlock ~= nil then
		return MigrationBlock
	end
	return OrderRule.JudgeOrder(Run, Op)
end

local function NoteDecision(Run: Run, Op: SentOp, Sequence: number, FateKind: WriterFateKind?)
	table.insert(Run.Decided, Op)
	if FateKind ~= nil then
		table.insert(Run.NewFates, { Sequence = Sequence, Kind = FateKind })
	end
end

local function RecordOp(Run: Run, Op: SentOp, Sequence: number, Fate: Fate)
	NoteDecision(Run, Op, Sequence, WriterFateKindOf(Fate))
	local Form = Op.Form
	local Limits = Run.Setup.Limits
	if Form.Kind == "Timed" then
		local Entry = NewTimedEntry(Limits, Op.OpKind, Form.Name, Op.Stamp, Fate)
		table.insert(Run.Book.Timed, Entry)
		Run.Written[Entry] = true
		return
	end
	if Form.Kind == "Untimed" then
		table.insert(Run.Book.Untimed, NewUntimedEntry(Limits, Op.OpKind, Form.Name, Run.Clock, Fate))
	end
end

local function FatedReport(Run: Run, Fate: Fate): Report
	if Fate.Kind == "Took" or Fate.Kind == "TookWith" then
		return { Kind = "Fated", Fate = Fate, State = nil }
	end
	return { Kind = "Fated", Fate = Fate, State = Run.State }
end

local function LookupKey(Run: Run, Form: OpForm): Report?
	if Form.Kind == "Tent" then
		return Tent.TentLookup(Run, Form)
	end
	if Form.Kind == "Commit" then
		return Decider.CommitLookup(Run, Form)
	end
	if Form.Kind == "Timed" or Form.Kind == "Untimed" then
		return Lookup.LookupName(Run, Form.Name)
	end
	return nil
end

local function GateReport(Run: Run, Form: OpForm): Report?
	if Form.Kind == "Tent" then
		return Tent.TentGate(Run)
	end
	if Form.Kind == "Commit" then
		return Decider.CommitGate(Run)
	end
	return nil
end

local function JudgeTxOp(Run: Run, Op: SentOp, Form: TentForm | CommitForm): Report
	local MigrationBlock = OrderRule.MigrationBlocks(Run)
	if MigrationBlock ~= nil then
		return MigrationBlock
	end
	if not IsMigrated(Run) then
		if Run.Book.Level >= Run.Setup.Build.MigrationCount then
			return { Kind = "Unreadable", Cause = "Balance" }
		end
		return Marks.WriteRefusal(Run, Op, Form.Name, { Kind = "Refused" })
	end
	if Form.Kind == "Tent" then
		return Tent.JudgeTent(Run, Op, Form)
	end
	return Decider.JudgeCommit(Run, Op, Form)
end

local function JudgeOp(Run: Run, Op: SentOp, Epoch: number): Report
	local Form = Op.Form
	if Form.Kind == "Cut" then
		error(CutNotJudged)
	end
	if IsOtherIncarnation(Run.Book, Op.Incarnation) then
		return StopWith(Run, OtherIncarnationReport(Run.Book))
	end
	if HasSequence(Form) then
		local DecidedBefore = Lookup.LookupWriter(Run, SequenceOf(Form))
		if DecidedBefore ~= nil then
			return DecidedBefore
		end
	end
	local Name = NameOf(Form)
	if Name ~= nil then
		AddAlsoCutWarning(Run, Name)
	end
	local KeyReport = LookupKey(Run, Form)
	if KeyReport ~= nil then
		return KeyReport
	end
	if IsForgotten(Run, Op) then
		return StopWith(Run, { Kind = "Forgotten" })
	end
	if IsBehind(Run) then
		return StopWith(Run, { Kind = "Behind" })
	end
	if IsAhead(Run, Op) then
		return StopWith(Run, { Kind = "Ahead" })
	end
	if IsViewCut(Run, Op) then
		if IsFatesFull(Run) then
			return StopWith(Run, { Kind = "Undecided" })
		end
		NoteDecision(Run, Op, SequenceOf(Form), "Cut")
		return { Kind = "Cut" }
	end
	local GateStopping = GateReport(Run, Form)
	if GateStopping ~= nil then
		return StopWith(Run, GateStopping)
	end
	if Form.Kind == "Tent" or Form.Kind == "Commit" then
		local CountBefore = #Run.Decided
		local TxOpReport = JudgeTxOp(Run, Op, Form)
		if #Run.Decided == CountBefore then
			return StopWith(Run, TxOpReport)
		end
		return TxOpReport
	end
	if Form.Kind == "Untimed" then
		local Stopping = JudgeClockAndUntimedRoom(Run, Op, Form.Name, Epoch)
		if Stopping ~= nil then
			return Stopping
		end
	end
	if Decide.UsesClock(Run.Setup, Op.OpKind) and not IsClockUsable(Run.Clock, Run.Setup.Limits) then
		return StopWith(Run, { Kind = "Undecided" })
	end
	if IsFatesFull(Run) then
		return StopWith(Run, { Kind = "Undecided" })
	end
	local OrderStopping = JudgeBesideMarks(Run, Op)
	if OrderStopping ~= nil then
		return StopWith(Run, OrderStopping)
	end
	local Decision = JudgeOneKey(Run, Op)
	local Stopping = Decide.StopOf(Decision)
	if Stopping ~= nil then
		return StopWith(Run, Stopping)
	end
	local Fate = Decide.FateOf(Decision)
	RecordOp(Run, Op, SequenceOf(Form), Fate)
	return FatedReport(Run, Fate)
end

local function JudgeOps(Run: Run)
	local Epoch = RoomEpoch(Run)
	for _, Op in Run.Request.Ops do
		if Run.IsStopped then
			local Undecided: Report = { Kind = "Undecided" }
			table.insert(Run.Reports, Undecided)
			continue
		end
		table.insert(Run.Reports, JudgeOp(Run, Op, Epoch))
	end
end

return {
	JudgeOps = JudgeOps,
	StopWith = StopWith,
	IsOtherIncarnation = IsOtherIncarnation,
	IsClockUsable = IsClockUsable,
}
