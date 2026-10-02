--!strict
--!optimize 2

--[=[
	CutRules: Logic. A Reset or an Erase inside Step, the gate it places, and what any request does
	on a key an erase sealed.

	Spec: cuts 2, 3.1, 3.3 and 3.4; record 4 step 1.1.

	A cut is called a cut because a Reset and an Erase each cut the key's state off from what came
	before. Judge runs the rules of cuts 3.1 in order. A cutter that meets marks places its gate in
	the same write, so no Tent lands between its look and its cut; a helper never places one. An
	Erase also waits on every pinned record. With nothing standing, a Reset names the money it
	destroys and replaces the state, and an Erase replaces the whole value by a seal. A seal is left
	over once Windows.SEAL_AGE has passed its rt: a request that may create the key then treats it as
	no key, and a seal stamp stamps it again. A stamp from the server that stamped rt, carrying that
	rt, lands at once. A stamp drops the namings once the cut's window has passed.

	Return type: A table with Judge, AgeGate and MeetSeal.
	Example usage:
		CutRules.Judge(Run, Request.Cut)
--]=]

local Book = require("./Book")
local Key = require("./Key")
local Limits = require("../Core/Constants/Limits")
local Losses = require("./Losses")
local Reduce = require("../Core/Reduce")
local Requests = require("./Requests")
local Runs = require("./Runs")
local Types = require("./Types")
local Windows = require("../Core/Constants/Windows")

type Run = Runs.Run

local Cause = Book.Cause
local Fate = Book.Fate
local Report = Types.Report
local Why = Types.Why

local CutRules = {}

local function Erase(Run: Run, Cut: Requests.Cut)
	local Record = Run.Record
	local Events = table.clone(Record.Events)
	local Amounts = Losses.Money(Run.State, Run.Build)
	if next(Amounts) then
		table.insert(Events, { Cause = Cause.Erase, Name = Cut.Name, Stamp = Run.Clock, Amounts = Amounts })
	end
	local Made: Book.Seal = {
		Name = Cut.Name,
		Stamp = Cut.Stamp,
		Print = Cut.Print,
		Server = Cut.Server,
		Rt = Run.Clock,
		Events = Events,
		Slots = table.clone(Record.Slots),
	}
	Run.Sealed = Made
	Run.Note.Seal = Made
	Run.Acted = true
	Runs.Report(Run, Report.Sealed)
end

local function Reset(Run: Run, Cut: Requests.Cut)
	local Record, Build = Run.Record, Run.Build
	local Amounts = Losses.Money(Run.State, Build)
	if next(Amounts) then
		local Events, Slots = table.clone(Record.Events), Reduce.Copy(Record.Slots)
		local Event: Book.Event = { Cause = Cause.Reset, Name = Cut.Name, Stamp = Run.Clock, Amounts = Amounts }
		local Wait = Losses.Name(Record, Build, Run.Clock, Run.Epoch, Event)
		if Wait then
			Record.Events = Events
			Record.Slots = Slots
			Run.Note.Wait = Wait
			return Runs.Report(Run, Report.Wait)
		end
	end
	Run.State = Reduce.Copy(Cut.State or Run.Given or Build.Default)
	Record.Level = Build.Level
	Record.Floor = Build.Floor
	Record.Cuts += 1
	Record.Cut[Cut.Name] = { Kind = Cut.Kind, Stamp = Cut.Stamp, Fate = Fate.Took, Print = Cut.Print }
	Run.Written[Cut.Name] = true
	if Record.Gate and Record.Gate.Name == Cut.Name then
		Record.Gate = nil
	end
	Run.Given = nil
	Run.Post = nil
	Run.Changed = true
	Run.Acted = true
	Runs.Report(Run, Report.Took)
end

local function Stamp(Seal: Book.Seal, Asked: Requests.Stamp, Clock: number, Build: Types.Build): Types.Note
	local Fresh = Clock - Seal.Stamp >= Build.CutWindow
	local Made: Book.Seal = {
		Name = Seal.Name,
		Stamp = Seal.Stamp,
		Print = Seal.Print,
		Server = Asked.Server,
		Rt = Clock,
		Events = if Fresh then {} else Seal.Events,
		Slots = if Fresh then {} else Seal.Slots,
	}
	local Note = Types.BlankNote()
	Note.Report = Report.Stamped
	Note.Seal = Made
	Note.Stored = Key.Sealed(Made)
	return Note
end

function CutRules.Judge(Run: Run, Cut: Requests.Cut)
	local Record, Build = Run.Record, Run.Build
	local Kept = Record.Cut[Cut.Name]
	if Kept then
		return Runs.Report(Run, if Kept.Kind == Cut.Kind and Kept.Print == Cut.Print then Report.Took else Report.Spent)
	end
	local Gate = Record.Gate
	local Own = Gate ~= nil and Gate.Name == Cut.Name
	if Gate and Own and (Gate.Kind ~= Cut.Kind or Gate.Print ~= Cut.Print) then
		return Runs.Report(Run, Report.Spent)
	elseif not Own and Cut.Stamp <= Record.CutHorizon then
		return Runs.Report(Run, Report.Forgotten)
	elseif Record.Floor > Build.Floor or Record.Level > Build.Level then
		return Runs.Report(Run, Report.Behind)
	elseif Run.Now == nil or (not Own and Cut.Stamp > math.max(Run.Clock, Record.CutHorizon) + Build.Ahead) then
		return Runs.Report(Run, Report.Ahead)
	elseif not Own and Cut.Helper then
		return Runs.Report(Run, Report.Gone)
	elseif Gate and not Own then
		Run.Note.Gate = Gate
		return Runs.ReportItems(Run, Report.GatedBy, Book.Marks(Record.Work))
	end
	local Standing = if Cut.Kind == Cause.Erase then table.clone(Record.Work) else Book.Marks(Record.Work)
	if next(Standing) then
		if Gate == nil and not Cut.Helper then
			Record.Gate = { Name = Cut.Name, Stamp = Cut.Stamp, Kind = Cut.Kind, Print = Cut.Print, At = Run.Clock }
			Run.Given = Cut.State
			Run.Acted = true
		end
		return Runs.ReportItems(Run, Report.Marks, Standing)
	elseif Cut.Kind == Cause.Erase then
		return Erase(Run, Cut)
	end
	return Reset(Run, Cut)
end

function CutRules.AgeGate(Record: Book.Book, Build: Types.Build, Now: number): boolean
	local Gate = Record.Gate
	if Gate == nil or Now - Gate.Stamp < Build.CutWindow then
		return false
	end
	Record.Gate = nil
	Record.CutHorizon = math.max(Record.CutHorizon, Gate.Stamp)
	return true
end

function CutRules.MeetSeal(Seal: Book.Seal, Request: Requests.Request, Clock: number, Build: Types.Build, MayCreate: boolean): Types.Note?
	local Left = Clock >= 0 and Clock <= Limits.STAMP_MAX and Clock - Seal.Rt >= Windows.SEAL_AGE
	local Cut, Asked = Request.Cut, Request.Stamp
	if Cut and Cut.Kind == Cause.Erase and Cut.Name == Seal.Name then
		local Note = Types.RefusedNote(Request, Why.Missing)
		Note.Why = nil
		Note.Report = if Cut.Print == Seal.Print then Report.Sealed else Report.Spent
		Note.Seal = Seal
		return Note
	elseif Asked and (Left or (Asked.Server == Seal.Server and Asked.Rt == Seal.Rt)) then
		return Stamp(Seal, Asked, Clock, Build)
	elseif Left and MayCreate then
		return nil
	end
	local Note = Types.RefusedNote(Request, Why.Missing)
	Note.Left = Left
	Note.Seal = Seal
	return Note
end

return CutRules
