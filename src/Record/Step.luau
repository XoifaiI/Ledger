--!strict
--!optimize 2

--[=[

	Step: The one transform every write to a game key runs, for the record's own ops.

	Step reads the key, then puts each op of the request down RULES in order until one has the last
	word. Then it sets the writer's entry, ages and fits the rooms, and writes when it decided
	anything. It gives back the value to write, or nil, and the note of what it found.

	The game's reducer runs behind a guard. The guard sets aside the top level fields the build does
	not declare and puts them back, and refuses a state that adds such a field or leaves a money field
	holding anything but a whole number below 2^53. Step measures the state it would write once. When
	that state is past the cap or cannot be stored, it runs the request again with a guard that
	measures after each op, so the op that crossed is Full and the ops after it are judged without it.

	Return type: A function that gives back the value to write, or nil, and the note.
	Example usage:
		local Step = require("./Step")
		local Value, Note = Step(Current, Request, Clock, Build)
--]=]

local RULES = require("./Rules")
local Book = require("./Book")
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
type Reducer = Reduce.Reducer<any, any>

local Fate = Book.Fate
local Why = Types.Why

local Guards: { [Build]: { Reducer } } = setmetatable({}, { __mode = "k" }) :: any

local function Guard(Build: Build, Capped: boolean): Reducer
	return function(State: { [string]: any }, Op: unknown): unknown
		local Aside: { [string]: any } = {}
		local Given = State
		for Field, Held in State do
			if Build.Fields[Field] then
				continue
			end
			if Given == State then
				Given = table.clone(State)
			end
			Aside[Field] = Held
			Given[Field] = nil
		end
		local Next = Build.Reducer(Given, Op)
		if type(Next) ~= "table" then
			return nil
		end
		local Result = Next :: { [string]: any }
		for Field in Result do
			if not Build.Fields[Field] then
				return nil
			end
		end
		for _, Field in Build.Money do
			local Amount = Result[Field]
			if not (type(Amount) == "number" and Amount % 1 == 0 and math.abs(Amount) < 2 ^ 53) then
				return nil
			end
		end
		for Field, Held in Aside do
			Result[Field] = Held
		end
		if not Capped then
			return Result
		end
		local Bytes = Value.Check(Result)
		if Bytes == nil then
			return nil
		end
		return if Bytes > Build.StateCap then Fate.Full else Result
	end
end

local function GuardOf(Build: Build, Capped: boolean): Reducer
	local Pair = Guards[Build]
	if Pair == nil then
		Pair = { Guard(Build, false), Guard(Build, true) }
		Guards[Build] = Pair
	end
	return Pair[if Capped then 2 else 1]
end

local function Refused(Request: Request, Reason: Types.Why): Note
	local Note: Note = { Fates = {}, Whys = {}, Decided = {}, Writes = 0, Cuts = 0, Horizon = 0, CutHorizon = 0, State = nil }
	for Index in Request.Ops do
		Note.Whys[Index] = Reason
	end
	return Note
end

local function Open(Current: unknown, Request: Request, Build: Build): (Book?, { [string]: any }?, Types.Why?)
	local Record, State, Reason = Key.Read(Current)
	if Reason or (Record and State) then
		return Record, State, Reason
	end
	local First = Request.Ops[1]
	if Request.MustExist or First == nil or First.Id ~= nil then
		return nil, nil, Why.Missing
	end
	local Made = Book.New()
	Made.Level, Made.Floor, Made.Id = Build.Level, Build.Floor, First.Create
	return Made, Reduce.Copy(Build.Default), nil
end

local function Begin(Current: unknown, Request: Request, Clock: number, Build: Build, Capped: boolean): (Run?, Types.Why?)
	local Record, State, Reason = Open(Current, Request, Build)
	if Record == nil or State == nil then
		return nil, Reason
	end
	if Record.Level < Build.Level then
		error("Step: running migrations is not in this build of Ledger yet", 0)
	elseif Record.Writes >= Limits.WRITES_MAX then
		return nil, Why.Worn
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
		Reducer = GuardOf(Build, Capped),
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
	return Run, nil
end

local function SetEntry(Run: Run)
	if Run.Entry == nil and Run.Minted == 0 then
		return
	end
	local Writer = Run.Request.Writer
	Run.Record.Writers[Writer] = { Id = Writer, Lo = Run.Last, Stamp = Run.Newest, Fates = Run.Fates }
end

local function Finish(Run: Run): (Key.Stored?, Note)
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
		return nil, Note
	end
	Record.Writes += 1
	Note.Writes, Note.Horizon, Note.CutHorizon, Note.State = Record.Writes, Record.Horizon, Record.CutHorizon, Run.State
	return Key.Store(Run.State, Record, Run.Epoch), Note
end

local function Attempt(Current: unknown, Request: Request, Clock: number, Build: Build, Capped: boolean): (Key.Stored?, Note)
	local Run, Reason = Begin(Current, Request, Clock, Build, Capped)
	if Run == nil then
		return nil, Refused(Request, Reason :: Types.Why)
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

local function Step(Current: unknown, Request: Request, Clock: number, Build: Build): (Key.Stored?, Note)
	local Written, Note = Attempt(Current, Request, Clock, Build, false)
	if Written == nil then
		return nil, Note
	end
	local Bytes = Value.Check(Written.s)
	if Bytes and Bytes <= Build.StateCap then
		return Written, Note
	end
	return Attempt(Current, Request, Clock, Build, true)
end

return Step
