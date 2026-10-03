--!strict
--!optimize 2

--[=[
	Step: Logic. The one transform every write to a game key runs.

	A ProveGone goes to CutRules before anything else, since it reads no record. Every other request
	is checked in one order: the key and its incarnation, the guards, the ends, then the request's
	one step, then each op through Rules. It then sets the writer's entry, ages and fits the rooms,
	and gives back a value only when something was decided or a step acted. Only an op judged for no
	key, a Tent, and a Commit within the minted window of its stamp may make a key, and only when no
	earlier run of the request wrote. A ProveGone writes only a seal. A key made for a request first
	sent more than that window before it landed says Late, since an erase may have come between.
	Every request but an end path write is refused Overdue while the work room holds an item
	Windows.CEILING old that it does not end. A write that changed the state clears the clean flag of
	every mark it did not place. A state past the cap, or one that cannot be stored, is judged again
	with the capped guard. The build's Upkeep runs after the ends and again before the rooms are
	aged.

	Return type: A function that gives back the note, whose Stored is the value to write or nil.
	Example usage:
		local Note = Step(Current, Request, Clock, Build)
--]=]

local RULES = require("./Rules")
local Book = require("./Book")
local CutRules = require("./CutRules")
local Guard = require("./Guard")
local Key = require("./Key")
local Limits = require("../Core/Constants/Limits")
local Losses = require("./Losses")
local Marks = require("./Marks")
local Reduce = require("../Core/Reduce")
local Requests = require("./Requests")
local Rooms = require("./Rooms")
local Runs = require("./Runs")
local TxRules = require("./TxRules")
local Types = require("./Types")
local Value = require("../Encode/Value")
local Windows = require("../Core/Constants/Windows")

type Build = Types.Build
type Note = Types.Note
type Request = Requests.Request
type Run = Runs.Run
type Guarded = (Build: Build) -> Reduce.Reducer<any, any>

local WorkForm = Book.WorkForm
local Why = Types.Why

local function Overdue(Run: Run): { [string]: Book.Work }?
	local Now, Request = Run.Now, Run.Request
	if Now == nil or Requests.IsEndPath(Request) then
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
	Made.Level = Build.Level
	Made.Floor = Build.Floor
	Made.Id = Create
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

local function Elsewhere(Run: Run, Asked: (Requests.Tent | Requests.Commit)?): boolean
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
	local Record = Found.Book
	if Record.Writes >= Limits.WRITES_MAX then
		return Why.Worn
	end
	local First = Sent(Request)
	local Late = Record.Writes == 0 and First ~= nil and Clock - First > Build.Minted
	return Runs.New(Request, Build, Found, Clock, Guarded(Build), Late)
end

local function Upkeep(Run: Run)
	local Keep, Now = Run.Build.Upkeep, Run.Now
	if Keep == nil or Now == nil then
		return
	end
	local Marked = false
	for _, Item in Run.Record.Work do
		Marked = Marked or Item.Form == WorkForm.Escrow
	end
	local Next = Keep(Run.State, Now, Marked)
	if Next ~= Run.State then
		Run.State = Next
		Run.Changed = true
	end
end

local function SetEntry(Run: Run)
	if Run.Entry == nil and Run.Minted == 0 then
		return
	end
	local Writer = Run.Request.Writer
	local Newest = assert(Run.Newest, "Step: a writer entry with no stamp decided")
	Run.Record.Writers[Writer] = { Id = Writer, Lo = Run.Last, Stamp = Newest, Fates = Run.Fates }
end

local function Finish(Run: Run): Note
	local Record, Note = Run.Record, Run.Note
	if Run.Folding then
		Run.State = Run.Folding.State
	end
	Upkeep(Run)
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
		Dropped = CutRules.AgeGate(Record, Run.Build, Run.Now) or Dropped
		Dropped = Losses.Age(Record, Run.Build, Run.Now) or Dropped
	end
	Rooms.Fit(Record, Run.Build, Run.Epoch, Run.Request.Writer, Run.Written)
	local Tidied = Run.Request.Tidy and Dropped
	if #Note.Decided == 0 and not Run.Acted and not Run.Request.Fresh and not Run.Request.Probe and not Tidied then
		return Note
	end
	Record.Writes += 1
	Note.Writes = Record.Writes
	Note.Horizon = Record.Horizon
	Note.CutHorizon = Record.CutHorizon
	Note.State = Run.State
	Note.Cuts = Record.Cuts
	Note.Stored = Key.Store(Run.State, Record, Run.Epoch, Run.Post, if Record.Gate then Run.Given else nil)
	return Note
end

local function Probed(Run: Run, Probe: Requests.Probe): Note
	local Working = Run.Record.Work[Probe.Name]
	if Working then
		if Working.Form == WorkForm.Pinned then
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
	if Request.ProveGone then
		return CutRules.ProveGone(Current, Request, Clock, Build)
	end
	local Seal = Key.Seal(Current)
	if Seal then
		local Note = CutRules.MeetSeal(Seal, Request, Clock, Build, MayCreate(Request, Clock, Build, Wrote))
		if Note then
			return Note
		end
		Current = nil
	end
	local Run = Begin(Current, Request, Clock, Build, Guarded, Wrote)
	if type(Run) == "string" then
		return Types.RefusedNote(Request, Run)
	end
	local Late = Overdue(Run)
	if Late then
		return Types.RefusedNote(Request, Why.Overdue, Late)
	end
	TxRules.Ends(Run)
	Upkeep(Run)
	local Probe, Tent, Commit, Fence, Cut = Request.Probe, Request.Tent, Request.Commit, Request.Fence, Request.Cut
	if Probe then
		return Probed(Run, Probe)
	elseif Elsewhere(Run, Tent or Commit) or (Cut and Cut.Id ~= nil and Cut.Id ~= Run.Record.Id) then
		Run.Note.Why = Why.Missing
	elseif Cut then
		CutRules.Judge(Run, Cut)
	elseif Tent then
		TxRules.Tent(Run, Tent)
	elseif Commit then
		TxRules.Commit(Run, Commit)
	elseif Fence then
		TxRules.Fence(Run, Fence)
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
