--!strict
--!optimize 2

--[=[

	Step: The one transform every write to a game key runs.

	Each op goes down RULES until one has the last word. Then the writer's entry is set, the rooms are
	aged and fitted, and a value comes back when anything was decided. A state past the cap, or one
	that cannot be stored, is judged again with the capped guard.

	Return type: A function that gives back the note, whose Stored is the value to write or nil.
	Example usage:
		local Note = Step(Current, Request, Clock, Build)
--]=]

local RULES = require("./Rules")
local Book = require("./Book")
local Guard = require("./Guard")
local Key = require("./Key")
local Limits = require("../Core/Constants/Limits")
local Reduce = require("../Core/Reduce")
local Rooms = require("./Rooms")
local Types = require("./Types")
local Value = require("../Encode/Value")

type Book = Book.Book
type Build = Types.Build
type Note = Types.Note
type Request = Types.Request
type Run = RULES.Run
type Guarded = (Build: Build) -> Reduce.Reducer<any, any>

local Why = Types.Why

local function Refused(Request: Request, Reason: Types.Why): Note
	local Note: Note = { Fates = {}, Whys = {}, Decided = {}, Writes = 0, Cuts = 0, Horizon = 0, CutHorizon = 0 }
	for Index in Request.Ops do
		Note.Whys[Index] = Reason
	end
	return Note
end

local function Open(Current: unknown, Request: Request, Build: Build): Key.Found | Types.Why
	local Found = Key.Read(Current)
	if Found then
		return Found
	end
	local First = Request.Ops[1]
	if Request.MustExist or First == nil or First.Id ~= nil then
		return Why.Missing
	end
	local Made = Book.New()
	Made.Level, Made.Floor, Made.Id = Build.Level, Build.Floor, First.Create
	return { Book = Made, State = Reduce.Copy(Build.Default) }
end

local function Begin(Current: unknown, Request: Request, Clock: number, Build: Build, Guarded: Guarded): Run | Types.Why
	local Found = Open(Current, Request, Build)
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
	if Run.Now then
		Rooms.Age(Record, Run.Build, Run.Now, Run.Request.Writer)
	end
	Rooms.Fit(Record, Run.Build, Run.Epoch, Run.Request.Writer, Run.Written)
	if #Note.Decided == 0 and not Run.Request.Fresh then
		return Note
	end
	Record.Writes += 1
	Note.Writes, Note.Horizon, Note.CutHorizon, Note.State = Record.Writes, Record.Horizon, Record.CutHorizon, Run.State
	Note.Stored = Key.Store(Run.State, Record, Run.Epoch)
	return Note
end

local function Attempt(Current: unknown, Request: Request, Clock: number, Build: Build, Guarded: Guarded): Note
	local Run = Begin(Current, Request, Clock, Build, Guarded)
	if type(Run) == "string" then
		return Refused(Request, Run)
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
