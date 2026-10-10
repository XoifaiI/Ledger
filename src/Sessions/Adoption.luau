--!strict
--!optimize 2

--[=[
	Adoption: what an open session does with a newer state or a turned-away op (record sheet 10 steps 3 and 4, and 13).

	A newer state, with its incarnation, is taken only above the session's write count. Queued hopeful ops lie on the
	stored state; a refused one stays queued, off the view. OnIdleRead says if it read a state. A Refresh made while
	this server's own transaction end is out on the key waits for it to land, then reads; one that waits for a read
	already out reads again after it, so the answer shows the end.

	Return type: A plain table of functions.
	Example usage:
		Adoption.TurnAway(Writer, Note, Commands)
		Adoption.Adopt(State, Sessions, Writer, Note, Clock, Commands)
--]=]

local Answering = require("../Writing/Answering")
local Answers = require("../Writing/Answers")
local Cache = require("../Reading/Cache")
local Events = require("../Events")
local JudgingShapes = require("../Judging/Shapes")
local Names = require("../Encoding/Names")
local Numbers = require("../Writing/Numbers")
local Reads = require("../Reading/Reads")
local Replies = require("../Replies")
local Session = require("./Session")
local Shapes = require("../Shapes")
local Shown = require("../Reading/Shown")
local Unreadable = require("../Reading/Unreadable")
local Value = require("../Stored/Value")
local View = require("../Reading/View")
local Writers = require("../Writing/Writer")

type Answer = Events.Answer
type Command = Events.Command
type ReadOutcome = Events.ReadOutcome
type Emitted = Answers.Emitted
type StoreKey = Names.StoreKey
type Basis = Session.Basis
type Session = Session.Session
type SessionState = Session.SessionState
type RefreshWait = Session.RefreshWait
type Note = JudgingShapes.Note
type Setup = Shapes.Setup
type WriterState = Shapes.WriterState
type ServerState = Shapes.ServerState
type Kept = Value.Kept
type Cause = Unreadable.Cause

type Fields = { [unknown]: unknown }

local TurnedForCut: Emitted = table.freeze({ Kind = "Turned" :: "Turned", Why = "Cut" :: "Cut", State = nil })

local function BasisOfNote(Note: Note, Viewed: Fields): Basis
	return {
		Writes = Note.Writes,
		Cuts = Note.Cuts,
		Horizon = Note.Horizon,
		Identity = Note.Identity,
		ShowsKey = Note.ShowsKey,
		Stored = Viewed,
		Marks = Note.Work,
	}
end

local function TakeAndShow(
	State: ServerState,
	Sessions: SessionState,
	Open: Session,
	Taken: Basis,
	Clock: number,
	Commands: { Command }
)
	Open.WriteCount = Taken.Writes
	Open.CutCount = Taken.Cuts
	Open.Horizon = Taken.Horizon
	Open.Identity = Taken.Identity
	Open.ShowsKey = Taken.ShowsKey
	Open.Stored = Taken.Stored
	Open.View = Session.QueuedOnStored(State, Open.Key, Taken.Stored, Taken.Marks, Clock)
	Open.Marks = Taken.Marks
	Open.IdleReadAt = Clock
	Shown.Show(State, Open.Key, Taken.Writes, Taken.Identity, Clock, Sessions.Open)
	Session.EmitView(Commands, Open)
end

local function TurnAway(Writer: WriterState, Note: Note, Commands: { Command }): number
	local Turned = 0
	for _, Op in Writer.Queue do
		if Op.IsHeard or Op.Form.Kind ~= "Hopeful" then
			continue
		end
		if Op.Form.ViewCuts >= Note.Cuts then
			continue
		end
		Writers.MarkHeard(Writer, Op)
		Writers.NoteTurnedAway(Writer, Op)
		Turned += 1
		if not Op.IsAnswered then
			Answering.FateOf(Commands, Writer, Op, TurnedForCut)
		end
	end
	return Turned
end

local function Adopt(
	State: ServerState,
	Sessions: SessionState,
	Writer: WriterState,
	Note: Note,
	Clock: number,
	Commands: { Command }
): boolean
	local Open = Sessions.Open[Writer.Text]
	if Open == nil or Note.Writes <= Open.WriteCount then
		return false
	end
	local Written = Note.WrittenValue
	if Written == nil or Written.Kind ~= "Kept" then
		return false
	end
	local Setup = Cache.StoreOf(State, Writer.Key).Setup
	local Viewed = View.ViewState(Setup, Written)
	if Viewed.Kind ~= "State" then
		return false
	end
	TakeAndShow(State, Sessions, Open, BasisOfNote(Note, Viewed.State), Clock, Commands)
	return true
end

local function ShowWithoutTurned(
	State: ServerState,
	Sessions: SessionState,
	Writer: WriterState,
	Clock: number,
	Commands: { Command }
)
	local Open = Sessions.Open[Writer.Text]
	if Open == nil then
		return
	end
	Open.View = Session.QueuedOnStored(State, Open.Key, Open.Stored, Open.Marks, Clock)
	Session.EmitView(Commands, Open)
end

local function IsIdleReadDue(State: ServerState, Open: Session, Clock: number): boolean
	if Open.IdleOut ~= nil then
		return false
	end
	local Store = Cache.StoreOf(State, Open.Key)
	if not Session.IsQuiet(Store.Writers[Open.Text]) then
		return false
	end
	return Clock - Open.IdleReadAt >= Store.Setup.Limits.IdleReadInterval
end

local function StartRead(
	State: ServerState,
	Sessions: SessionState,
	Open: Session,
	Clock: number,
	Commands: { Command }
)
	local RequestId = Numbers.NewRequestId(State)
	local Get: Command = { Kind = "Get", RequestId = RequestId, Target = Open.Key }
	table.insert(Commands, Get)
	Open.IdleOut = RequestId
	Open.IdleReadAt = Clock
	Sessions.IdleReads[RequestId] = Open.Text
end

local function IdleRead(
	State: ServerState,
	Sessions: SessionState,
	Open: Session,
	Clock: number,
	Commands: { Command }
): boolean
	if not IsIdleReadDue(State, Open, Clock) then
		return false
	end
	StartRead(State, Sessions, Open, Clock, Commands)
	return true
end

local function Refresh(
	State: ServerState,
	Sessions: SessionState,
	Open: Session,
	CallId: number,
	Clock: number,
	IsAfterEnds: boolean,
	Commands: { Command }
)
	local Limits = Cache.StoreOf(State, Open.Key).Setup.Limits
	local Wait: RefreshWait? = if IsAfterEnds then "Ends" else nil
	table.insert(
		Sessions.Refreshing,
		{ CallId = CallId, Text = Open.Text, Deadline = Clock + Limits.OpBound, Wait = Wait }
	)
	if Wait == nil and Open.IdleOut == nil then
		StartRead(State, Sessions, Open, Clock, Commands)
	end
end

local function ReadAgainFor(
	State: ServerState,
	Sessions: SessionState,
	Open: Session,
	Waited: RefreshWait,
	Clock: number,
	Commands: { Command }
)
	local IsWaiting = false
	for _, Pending in Sessions.Refreshing do
		if Pending.Text == Open.Text and Pending.Wait == Waited then
			Pending.Wait = if Open.IdleOut == nil then nil else "Read"
			IsWaiting = IsWaiting or Pending.Wait == nil
		end
	end
	if IsWaiting then
		StartRead(State, Sessions, Open, Clock, Commands)
	end
end

local function ReadAfterEnds(
	State: ServerState,
	Sessions: SessionState,
	Key: StoreKey,
	Clock: number,
	Commands: { Command }
)
	local Open = Sessions.Open[Names.KeyText(Key)]
	if Open ~= nil then
		ReadAgainFor(State, Sessions, Open, "Ends", Clock, Commands)
	end
end

local function UnreadableAnswer(State: ServerState, Open: Session, Cause: Cause, Commands: { Command }): Answer
	Unreadable.Warn(State, Open.Key, Cause, Commands)
	if Cause == "Newer" then
		Open.IsBehind = true
	end
	return Replies.FailedAnswer(Unreadable.ReasonOf(Cause))
end

local function AdoptRead(
	State: ServerState,
	Sessions: SessionState,
	Open: Session,
	Read: Kept,
	Setup: Setup,
	Clock: number,
	Commands: { Command }
): Answer
	if View.IsBehind(Setup, Read) then
		Open.IsBehind = true
		return Reads.BehindAnswer
	end
	local Writes = Read.Book.Writes
	if Writes <= Open.WriteCount then
		return Replies.DoneAnswer
	end
	local Viewed = View.ViewState(Setup, Read)
	if Viewed.Kind == "Unreadable" then
		return UnreadableAnswer(State, Open, Viewed.Cause, Commands)
	end
	if Viewed.Kind ~= "State" then
		return Reads.UnresolvedAnswer
	end
	if not Shown.IsShown(State, Open.Key, Writes, Read.Book.Identity) then
		return Replies.DoneAnswer
	end
	TakeAndShow(State, Sessions, Open, Session.BasisOfKept(Read, Viewed.State), Clock, Commands)
	return Replies.DoneAnswer
end

local function TakeRead(
	State: ServerState,
	Sessions: SessionState,
	Open: Session,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
): (Answer, boolean)
	if Fetched.Kind == "Failed" then
		return Reads.UnresolvedAnswer, false
	end
	local Setup = Cache.StoreOf(State, Open.Key).Setup
	local Read = Numbers.LearnStored(State, Open.Key, Setup, Fetched, Clock)
	if Read.Kind == "Unreadable" then
		return UnreadableAnswer(State, Open, Read.Cause, Commands), false
	end
	if Read.Kind ~= "Kept" then
		return Replies.DoneAnswer, false
	end
	return AdoptRead(State, Sessions, Open, Read.Kept, Setup, Clock, Commands), true
end

local function OnIdleRead(
	State: ServerState,
	Sessions: SessionState,
	Key: StoreKey,
	RequestId: number,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
): boolean
	local Open = Sessions.Open[Names.KeyText(Key)]
	if Open == nil or Open.IdleOut ~= RequestId then
		return false
	end
	Open.IdleOut = nil
	local Given, IsRead = TakeRead(State, Sessions, Open, Fetched, Clock, Commands)
	Session.AnswerRefreshes(Sessions, Open.Text, Given, Commands)
	ReadAgainFor(State, Sessions, Open, "Read", Clock, Commands)
	return IsRead
end

return {
	TurnAway = TurnAway,
	Adopt = Adopt,
	ShowWithoutTurned = ShowWithoutTurned,
	IsIdleReadDue = IsIdleReadDue,
	IdleRead = IdleRead,
	Refresh = Refresh,
	ReadAfterEnds = ReadAfterEnds,
	OnIdleRead = OnIdleRead,
}
