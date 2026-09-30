--!strict
--!optimize 2

--[=[

	Step: Logic. The one transform every write to a game key runs.

	Spec: record 4.

	The ends a request carries go first. Then each op goes down RULES until one has the last word, or
	the request's transaction step runs. Then the writer's entry is set, the rooms are aged and
	fitted, and a value comes back when anything was decided or acted. A write that changed the state
	clears the clean flag of every mark it did not place. A state past the cap, or one that cannot be
	stored, is judged again with the capped guard. A fresh read decides nothing and lands. A probe
	decides nothing: a held name gives its fate, a stamp at or under the horizon is forgotten, and any
	other probe lands. Only an op judged for no key, a Tent, and a Commit within the minted window of
	its stamp may create a key. A request that is not an end path write, one of only ends and a
	fence, is refused Overdue while the work room holds an item Windows.CEILING old that it does not
	end, and the note lists those items.

	Return type: A function that gives back the note, whose Stored is the value to write or nil.
	Example usage:
		local Note = Step(Current, Request, Clock, Build)
--]=]

local RULES = require("./Rules")
local Book = require("./Book")
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
	return Request.Ops[1] == nil and not (Request.Tent or Request.Commit or Request.Fresh or Request.Probe)
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
	local Late: { [string]: Book.Work } = {}
	for Name, Item in Run.Record.Work do
		if Now - Item.Stamp >= Windows.CEILING and not Ended[Name] then
			Late[Name] = Item
		end
	end
	return if next(Late) then Late else nil
end

local function MayCreate(Request: Request, Clock: number, Build: Build): boolean
	local First, Commit = Request.Ops[1], Request.Commit
	if Request.MustExist then
		return false
	elseif First then
		return First.Id == nil
	elseif Commit then
		return Clock - Commit.Stamp <= Build.Minted
	end
	return Request.Tent ~= nil
end

local function Open(Current: unknown, Request: Request, Clock: number, Build: Build): Key.Found | Types.Why
	local Found = Key.Read(Current)
	if Found then
		return Found
	elseif not MayCreate(Request, Clock, Build) then
		return Why.Missing
	end
	local First = Request.Ops[1]
	local Made = Book.New()
	Made.Level, Made.Floor, Made.Id = Build.Level, Build.Floor, if First then First.Create else nil
	return { Book = Made, State = Reduce.Copy(Build.Default) }
end

local function Begin(Current: unknown, Request: Request, Clock: number, Build: Build, Guarded: Guarded): Run | Types.Why
	local Found = Open(Current, Request, Clock, Build)
	if type(Found) == "string" then
		return Found
	end
	local Record, State = Found.Book, Found.State
	if Record.Writes >= Limits.WRITES_MAX then
		return Why.Worn
	end

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
	if Run.Now then
		Rooms.Age(Record, Run.Build, Run.Now, Run.Request.Writer)
	end
	Rooms.Fit(Record, Run.Build, Run.Epoch, Run.Request.Writer, Run.Written)
	if #Note.Decided == 0 and not Run.Acted and not Run.Request.Fresh and not Run.Request.Probe then
		return Note
	end
	Record.Writes += 1
	Note.Writes, Note.Horizon, Note.CutHorizon, Note.State = Record.Writes, Record.Horizon, Record.CutHorizon, Run.State
	Note.Stored = Key.Store(Run.State, Record, Run.Epoch, Run.Post)
	return Note
end

local function Probed(Run: Run, Probe: Types.Probe): Note
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

local function Attempt(Current: unknown, Request: Request, Clock: number, Build: Build, Guarded: Guarded): Note
	local Run = Begin(Current, Request, Clock, Build, Guarded)
	if type(Run) == "string" then
		return Refused(Request, Run)
	end
	local Late = Overdue(Run)
	if Late then
		return Refused(Request, Why.Overdue, Late)
	end
	Work.Ends(Run)
	local Probe, Tent, Commit, Fence = Request.Probe, Request.Tent, Request.Commit, Request.Fence
	if Probe then
		return Probed(Run, Probe)
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

local function Step(Current: unknown, Request: Request, Clock: number, Build: Build): Note
	local Note = Attempt(Current, Request, Clock, Build, Guard.Plain)
	local Stored = Note.Stored
	if Stored == nil then
		return Note
	end
	local Bytes = Value.Check(Stored.s)
	if Bytes and Bytes <= Build.StateCap then
		return Note
	end
	return Attempt(Current, Request, Clock, Build, Guard.Capped)
end

return Step
