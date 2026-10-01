--!strict
--!optimize 2

--[=[

	Step: Logic. The one transform every write to a game key runs.

	Spec: record 4.

	The ends a request carries go first. Then each op goes down RULES until one has the last word,
	or the request's transaction step runs. Then the writer's entry is set, the rooms are aged and
	fitted, and a value comes back when anything was decided or acted. A write that changed the
	state clears the clean flag of every mark it did not place. A state past the cap, or one that
	cannot be stored, is judged again with the capped guard. A fresh read decides nothing and lands.
	A probe decides nothing. A held name gives its fate, and a pinned use took. A standing mark is
	undecided, and a stamp at or under the horizon is forgotten. Any other probe lands. Only an op
	judged for no key, a Tent, and a Commit within the minted window of its stamp may create a key.
	Each may create it only when no earlier run of the request wrote. The key it makes takes the id
	the request carries. A Tent or a Commit judged for another incarnation is Missing. An end path
	write carries only ends and a fence. Any other request is refused Overdue while the work room
	holds an item Windows.CEILING old that it does not end. The note lists those items. A cut is
	judged by Cuts after the ends. A gate keeps the state a Reset was given while it stands. A key
	made by a request first sent more than the minted window before it lands says Late. A key that
	holds a seal answers its own erase Sealed and every other request Missing. A seal
	Windows.SEAL_AGE past its rt is left over. A request that may create a key replaces a left over
	seal, and a seal stamp stamps it again. A stamp from the server that stamped rt, carrying that
	rt, lands at once. A stamp drops the namings once the seal is the cut window old. A tidy carries
	no op and lands only when the age step dropped something.

	Return type: A function that gives back the note, whose Stored is the value to write or nil.
	Example usage:
		local Note = Step(Current, Request, Clock, Build)
--]=]

local RULES = require("./Rules")
local Book = require("./Book")
local Cuts = require("./Cuts")
local Guard = require("./Guard")
local Key = require("./Key")
local Limits = require("../Core/Constants/Limits")
local Marks = require("./Marks")
local Reduce = require("../Core/Reduce")
local Rooms = require("./Rooms")
local Work = require("./Work")
local Types = require("./Types")
local Value = require("../Encode/Value")
local Windows = require("../Core/Constants/Windows")

type Book = Book.Book
type Build = Types.Build
type Note = Types.Note
type Request = Types.Request
type Run = RULES.Run
type Guarded = (Build: Build) -> Reduce.Reducer<any, any>

local Why = Types.Why

local function Refused(Request: Request, Reason: Types.Why, Items: { [string]: Book.Work }?): Note
	local Note: Note = {
		Fates = {},
		Whys = {},
		Decided = {},
		Writes = 0,
		Cuts = 0,
		Horizon = 0,
		CutHorizon = 0,
		Why = Reason,
		Items = Items,
	}
	for Index in Request.Ops do
		Note.Whys[Index] = Reason
	end
	return Note
end

local function EndPath(Request: Request): boolean
	return Request.Ops[1] == nil and not (Request.Tent or Request.Commit or Request.Fresh or Request.Probe or Request.Cut or Request.Stamp)
end

local function Overdue(Run: Run): { [string]: Book.Work }?
	local Now, Request = Run.Now, Run.Request
	if Now == nil or EndPath(Request) then
		return nil
	end
	local Ended: { [string]: true } = {}
	for _, End in Request.Ends or {} do
		Ended[End.Name] = true
	end
	for _, Name in Request.Drops or {} do
		Ended[Name] = true
	end
	for _, Orphan in Request.Orphans or {} do
		Ended[Orphan.Name] = true
	end
	local Late: { [string]: Book.Work } = {}
	for Name, Item in Run.Record.Work do
		if Now - Item.Stamp >= Windows.CEILING and not Ended[Name] then
			Late[Name] = Item
		end
	end
	return if next(Late) then Late else nil
end

local function Judged(Request: Request): (string?, string?)
	local First = Request.Ops[1]
	if First then
		return First.Id, First.Create
	end
	local Asked = Request.Tent or Request.Commit
	if Asked then
		return Asked.Id, Asked.Create
	end
	return nil, nil
end

local function MayCreate(Request: Request, Clock: number, Build: Build, Wrote: boolean): boolean
	local Commit = Request.Commit
	if Request.MustExist or Wrote or (Judged(Request)) ~= nil then
		return false
	elseif Request.Ops[1] then
		return true
	elseif Commit then
		return Clock - Commit.Stamp <= Build.Minted
	end
	return Request.Tent ~= nil
end

local function Open(Current: unknown, Request: Request, Clock: number, Build: Build, Wrote: boolean): Key.Found | Types.Why
	local Found = Key.Read(Current)
	if Found then
		return Found
	elseif not MayCreate(Request, Clock, Build, Wrote) then
		return Why.Missing
	end
	local _, Create = Judged(Request)
	local Made = Book.New()
	Made.Level, Made.Floor, Made.Id = Build.Level, Build.Floor, Create
	return { Book = Made, State = Reduce.Copy(Build.Default) }
end

local function Sent(Request: Request): number?
	local First = Request.Ops[1]
	if First then
		return First.Stamp
	end
	local Asked = Request.Tent or Request.Commit
	return if Asked then Asked.Stamp else nil
end

local function Elsewhere(Run: Run, Asked: (Types.Tent | Types.Commit)?): boolean
	if Asked == nil then
		return false
	end
	local Id = Asked.Create or Asked.Id
	return Id ~= nil and Id ~= Run.Record.Id
end

local function Begin(Current: unknown, Request: Request, Clock: number, Build: Build, Guarded: Guarded, Wrote: boolean): Run | Types.Why
	local Found = Open(Current, Request, Clock, Build, Wrote)
	if type(Found) == "string" then
		return Found
	end
	local Record, State = Found.Book, Found.State
	if Record.Writes >= Limits.WRITES_MAX then
		return Why.Worn
	end
	local First = Sent(Request)
	local Late = Record.Writes == 0 and First ~= nil and Clock - First > Build.Minted

	local Entry = Record.Writers[Request.Writer]
	local Fates: { [number]: number } = {}
	local FatesHeld = 0
	for Seq, Code in if Entry then Entry.Fates else {} do
		if Seq > Request.Ack then
			Fates[Seq] = Code
			FatesHeld += 1
		end
	end
	local Now = if Clock >= 0 and Clock <= Limits.STAMP_MAX then Clock else nil
	local Epoch = Now or math.max(Record.Horizon, 0)
	local Run: Run = {
		Request = Request,
		Build = Build,
		Record = Record,
		Entry = Entry,
		Note = {
			Fates = {},
			Whys = {},
			Decided = {},
			Writes = Record.Writes,
			Cuts = Record.Cuts,
			Horizon = Record.Horizon,
			CutHorizon = Record.CutHorizon,
			Id = Record.Id,
			State = State,
			Late = if Late then true else nil,
		},
		Reducer = Guarded(Build),
		Clock = Clock,
		Now = Now,
		Epoch = Epoch,
		State = State,
		Folding = nil,
		Stop = nil,
		Fates = Fates,
		FatesHeld = FatesHeld,
		Minted = 0,
		Newest = if Entry then Entry.Stamp else -math.huge,
		Last = if Entry then Entry.Lo else 0,
		Written = {},
		UntimedBytes = Rooms.Untimed(Record, Epoch),
		Post = Found.Post,
		Given = Found.Given,
		Changed = false,
		Acted = false,
	}
	return Run
end

local function SetEntry(Run: Run)
	if Run.Entry == nil and Run.Minted == 0 then
		return
	end
	local Writer = Run.Request.Writer
	Run.Record.Writers[Writer] = { Id = Writer, Lo = Run.Last, Stamp = Run.Newest, Fates = Run.Fates }
end

local function Finish(Run: Run): Note
	local Record, Note = Run.Record, Run.Note
	if Run.Folding then
		Run.State = Run.Folding.State
	end
	SetEntry(Run)
	if Run.Changed then
		Marks.Unclean(Record.Work, Run.Placed)
	end
	if Run.Sealed then
		Note.Stored = Key.Sealed(Run.Sealed)
		return Note
	end
	local Dropped = false
	if Run.Now then
		Dropped = Rooms.Age(Record, Run.Build, Run.Now, Run.Request.Writer)
		Dropped = Cuts.Age(Record, Run.Build, Run.Now) or Dropped
	end
	Rooms.Fit(Record, Run.Build, Run.Epoch, Run.Request.Writer, Run.Written)
	local Tidied = Run.Request.Tidy and Dropped
	if #Note.Decided == 0 and not Run.Acted and not Run.Request.Fresh and not Run.Request.Probe and not Tidied then
		return Note
	end
	Record.Writes += 1
	Note.Writes, Note.Horizon, Note.CutHorizon, Note.State = Record.Writes, Record.Horizon, Record.CutHorizon, Run.State
	Note.Cuts = Record.Cuts
	Note.Stored = Key.Store(Run.State, Record, Run.Epoch, Run.Post, if Record.Gate then Run.Given else nil)
	return Note
end

local function Stamped(Seal: Book.Seal, Stamp: Types.Stamp, Clock: number, Build: Build): Note
	local Fresh = Clock - Seal.Stamp >= Build.CutWindow
	local Made: Book.Seal = {
		Name = Seal.Name,
		Stamp = Seal.Stamp,
		Print = Seal.Print,
		Server = Stamp.Server,
		Rt = Clock,
		Events = if Fresh then {} else Seal.Events,
		Slots = if Fresh then {} else Seal.Slots,
	}
	local Note: Note = { Fates = {}, Whys = {}, Decided = {}, Writes = 0, Cuts = 0, Horizon = 0, CutHorizon = 0 }
	Note.Report, Note.Seal, Note.Stored = Types.Report.Stamped, Made, Key.Sealed(Made)
	return Note
end

local function Sealed(Seal: Book.Seal, Request: Request, Clock: number, Build: Build, Wrote: boolean): Note?
	local Left = Clock >= 0 and Clock <= Limits.STAMP_MAX and Clock - Seal.Rt >= Windows.SEAL_AGE
	local Cut, Stamp = Request.Cut, Request.Stamp
	if Cut and Cut.Kind == Book.Cause.Erase and Cut.Name == Seal.Name then
		local Note = Refused(Request, Why.Missing)
		Note.Why = nil
		Note.Report, Note.Seal = if Cut.Print == Seal.Print then Types.Report.Sealed else Types.Report.Spent, Seal
		return Note
	elseif Stamp and (Left or (Stamp.Server == Seal.Server and Stamp.Rt == Seal.Rt)) then
		return Stamped(Seal, Stamp, Clock, Build)
	elseif Left and MayCreate(Request, Clock, Build, Wrote) then
		return nil
	end
	local Note = Refused(Request, Why.Missing)
	Note.Left, Note.Seal = Left, Seal
	return Note
end

local function Probed(Run: Run, Probe: Types.Probe): Note
	local Working = Run.Record.Work[Probe.Name]
	if Working then
		if Working.Form == "Pinned" then
			Run.Note.Held = Book.Fate.Took
		else
			Run.Note.Why = Why.Undecided
		end
		return Run.Note
	end
	local Item = Run.Record:Held(Probe.Name)
	if Item then
		Run.Note.Held = Item.Fate
		return Run.Note
	elseif Probe.Stamp <= Run.Record.Horizon then
		Run.Note.Why = Why.Forgotten
		return Run.Note
	end
	return Finish(Run)
end

local function Attempt(Current: unknown, Request: Request, Clock: number, Build: Build, Guarded: Guarded, Wrote: boolean): Note
	local Seal = Key.Seal(Current)
	if Seal then
		local Note = Sealed(Seal, Request, Clock, Build, Wrote)
		if Note then
			return Note
		end
		Current = nil
	end
	local Run = Begin(Current, Request, Clock, Build, Guarded, Wrote)
	if type(Run) == "string" then
		return Refused(Request, Run)
	end
	local Late = Overdue(Run)
	if Late then
		return Refused(Request, Why.Overdue, Late)
	end
	Work.Ends(Run)
	local Probe, Tent, Commit, Fence, Cut = Request.Probe, Request.Tent, Request.Commit, Request.Fence, Request.Cut
	if Probe then
		return Probed(Run, Probe)
	elseif Elsewhere(Run, Tent or Commit) or (Cut and Cut.Id ~= nil and Cut.Id ~= Run.Record.Id) then
		Run.Note.Why = Why.Missing
	elseif Cut then
		Cuts.Judge(Run, Cut)
	elseif Tent then
		Work.Tent(Run, Tent)
	elseif Commit then
		Work.Commit(Run, Commit)
	elseif Fence then
		Work.Fence(Run, Fence)
	end
	for Index, Op in Request.Ops do
		for _, Rule in RULES do
			if Rule(Run, Index, Op) then
				break
			end
		end
	end
	return Finish(Run)
end

local function Step(Current: unknown, Request: Request, Clock: number, Build: Build, Wrote: boolean?): Note
	local Earlier = Wrote == true
	local Note = Attempt(Current, Request, Clock, Build, Guard.Plain, Earlier)
	local Stored = Note.Stored
	if Stored == nil then
		return Note
	end
	local Bytes = Value.Check(Stored.s)
	if Stored.z or (Bytes and Bytes <= Build.StateCap) then
		return Note
	end
	return Attempt(Current, Request, Clock, Build, Guard.Capped, Earlier)
end

return Step
