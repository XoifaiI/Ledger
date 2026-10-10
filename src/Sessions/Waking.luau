--!strict
--!optimize 2

--[=[
	Waking: the writers' and sessions' timers and the wake for the next of them (record sheet 7 cases 2 and 6, 10, 13).

	After a Clock they are computed in full, after any other event only for the keys in TimersMoved: a kept wake may
	be early, never late. Shedding waits for the kept queue deadline. Only Step.FullWake calls TrueWake.

	Return type: A plain table of functions.
	Example usage:
		Waking.OnClock(State, Clock, Commands)
		local At = Waking.NextWake(State, Clock)
--]=]

local Adoption = require("./Adoption")
local Cache = require("../Reading/Cache")
local Closing = require("./Closing")
local Composed = require("../Composed")
local Events = require("../Events")
local Hearing = require("../Writing/Hearing")
local Names = require("../Encoding/Names")
local OpForms = require("../Judging/OpForms")
local Pacing = require("../Writing/Pacing")
local Session = require("./Session")
local Shapes = require("../Shapes")
local Shedding = require("../Writing/Shedding")
local Sorted = require("../Sorted")
local Writers = require("../Writing/Writer")
local Writing = require("../Writing/Writing")

type Command = Events.Command
type StoreKey = Names.StoreKey
type State = Composed.State
type KeptWake = Composed.KeptWake
type Session = Session.Session
type Limits = Shapes.Limits
type WriterState = Shapes.WriterState

local EarliestAfter = Composed.EarliestAfter
local IsDurable = OpForms.IsDurable

local function EarlierOf(Soonest: number?, At: number?): number?
	if At == nil then
		return Soonest
	end
	if Soonest == nil or At < Soonest then
		return At
	end
	return Soonest
end

local function WriterTimers(Writer: WriterState, Limits: Limits, Clock: number): (number?, number?)
	local Soonest = EarliestAfter(nil, Writer.RetryAt, Clock)
	if Writer.Paced ~= nil then
		Soonest = EarliestAfter(Soonest, Pacing.NextSendAt(Writer.Paced), Clock)
	end
	Soonest = EarliestAfter(Soonest, Writers.IdleDropAt(Writer, Limits), Clock)
	local ShedAt: number? = nil
	for _, Op in Writer.Queue do
		if Op.IsHeard or not IsDurable(Op.Form) then
			continue
		end
		if Op.IsSent then
			Soonest = EarliestAfter(Soonest, Shedding.OpBoundAt(Writer, Op, Limits), Clock)
			continue
		end
		local Deadline = Shedding.OpDeadline(Writer, Op, Limits)
		Soonest = EarliestAfter(Soonest, Deadline, Clock)
		ShedAt = EarlierOf(ShedAt, Deadline)
	end
	for _, Waiting in Writer.Waiting do
		if Waiting.Form.Kind ~= "Hopeful" then
			local Deadline = Shedding.WaitingDeadline(Writer, Waiting, Limits)
			Soonest = EarliestAfter(Soonest, Deadline, Clock)
			ShedAt = EarlierOf(ShedAt, Deadline)
		end
	end
	return Soonest, ShedAt
end

local function SessionWake(Open: Session, Writer: WriterState?, Limits: Limits, Clock: number): number?
	if Writer == nil or Session.IsQuiet(Writer) then
		return EarliestAfter(nil, Open.IdleReadAt + Limits.IdleReadInterval, Clock)
	end
	return EarliestAfter(nil, Open.PushedAt + Limits.SaveInterval, Clock)
end

local function KeyTimers(State: State, Text: string, Key: StoreKey, Clock: number): (number?, number?)
	local Store = Cache.StoreOf(State.Server, Key)
	local Limits = Store.Setup.Limits
	local Writer = Store.Writers[Text]
	local Soonest: number? = nil
	local ShedAt: number? = nil
	if Writer ~= nil then
		Soonest, ShedAt = WriterTimers(Writer, Limits, Clock)
	end
	local Open = State.Sessions.Open[Text]
	if Open ~= nil then
		Soonest = EarliestAfter(Soonest, SessionWake(Open, Writer, Limits, Clock), Clock)
	end
	return Soonest, ShedAt
end

local function KeysWake(State: State, Clock: number): (number?, number?)
	local Soonest: number? = nil
	local ShedAt: number? = nil
	for _, Store in State.Server.Stores do
		local Limits = Store.Setup.Limits
		for _, Writer in Store.Writers do
			local WriterWake, WriterShedAt = WriterTimers(Writer, Limits, Clock)
			Soonest = EarliestAfter(Soonest, WriterWake, Clock)
			ShedAt = EarlierOf(ShedAt, WriterShedAt)
		end
	end
	for Text, Open in State.Sessions.Open do
		local Store = Cache.StoreOf(State.Server, Open.Key)
		Soonest = EarliestAfter(Soonest, SessionWake(Open, Store.Writers[Text], Store.Setup.Limits, Clock), Clock)
	end
	return Soonest, ShedAt
end

local function ClosingWake(State: State, Clock: number): number?
	local Soonest: number? = nil
	for _, Pending in State.Sessions.Releasing do
		Soonest = EarliestAfter(Soonest, Pending.Deadline, Clock)
	end
	local Ending = State.Sessions.Shutdown
	if Ending ~= nil and Ending.Kind == "Ending" then
		Soonest = EarliestAfter(Soonest, Ending.Deadline, Clock)
	end
	return Soonest
end

local function SharedWake(State: State, Clock: number): number?
	local Soonest = ClosingWake(State, Clock)
	for _, Reading in State.Incarnations do
		Soonest = EarliestAfter(Soonest, Reading.RetryAt, Clock)
	end
	for _, Flush in State.Flushing do
		Soonest = EarliestAfter(Soonest, Flush.Deadline, Clock)
	end
	for _, Pending in State.Sessions.Refreshing do
		Soonest = EarliestAfter(Soonest, Pending.Deadline, Clock)
	end
	return Soonest
end

local function SoonestOf(Kept: { [string]: number }): number?
	local Soonest: number? = nil
	for _, At in Kept do
		Soonest = EarlierOf(Soonest, At)
	end
	return Soonest
end

local function FoldKey(Soonest: number?, IsStale: boolean, Old: number?, New: number?): (number?, boolean)
	if New ~= nil and (Soonest == nil or New < Soonest) then
		return New, false
	end
	return Soonest, IsStale or (Old ~= nil and Old == Soonest)
end

local function KeepKey(Kept: KeptWake, Text: string, Key: StoreKey, KeyWake: number?, KeyShedAt: number?)
	Kept.KeyAt[Text] = KeyWake
	Kept.KeyShedAt[Text] = KeyShedAt
	Kept.KeyOf[Text] = if KeyWake == nil and KeyShedAt == nil then nil else Key
end

local function ShedPastDeadline(State: State, Clock: number, Commands: { Command })
	local Kept = State.Wake
	local KeptShedAt = Kept.ShedAt
	if Kept.IsKnown and (KeptShedAt == nil or Clock < KeptShedAt) then
		return
	end
	local Server = State.Server
	for _, Name in Sorted.SortedTexts(Server.Stores) do
		local Store = Server.Stores[Name]
		local Limits = Store.Setup.Limits
		local function IsPast(Writer: WriterState): boolean
			return Shedding.HasPastDeadline(Writer, Clock, Limits)
		end
		for _, Text in Sorted.SortedDueTexts(Store.Writers, IsPast) do
			local Writer = Store.Writers[Text]
			Shedding.ShedUnsent(Server, Writer, Clock, Limits, Commands)
			Composed.NoteTimersMovedAt(State, Text, Writer.Key)
		end
		for Text, Writer in Store.Writers do
			local _, WriterShedAt = WriterTimers(Writer, Limits, Clock)
			Kept.KeyShedAt[Text] = WriterShedAt
		end
	end
	Kept.ShedAt = SoonestOf(Kept.KeyShedAt)
end

local function OnClock(State: State, Clock: number, Commands: { Command })
	local Server = State.Server
	for _, Name in Sorted.SortedTexts(Server.Stores) do
		local Store = Server.Stores[Name]
		local Limits = Store.Setup.Limits
		local function IsDue(Writer: WriterState): boolean
			return Shedding.HasPastDeadline(Writer, Clock, Limits) or Shedding.HasTimedOut(Writer, Clock, Limits)
		end
		for _, Text in Sorted.SortedDueTexts(Store.Writers, IsDue) do
			local Writer = Store.Writers[Text]
			Shedding.ShedUnsent(Server, Writer, Clock, Limits, Commands)
			Shedding.TimeOut(Server, Writer, Clock, Limits, Commands)
		end
		for Text, Writer in Store.Writers do
			Writers.PruneHeard(Writer, Clock)
			if Writer.RetryAt ~= nil and Clock >= Writer.RetryAt then
				Composed.NoteSendableAt(State, Text, Writer.Key)
			end
			if Writer.Paced ~= nil and Clock >= Pacing.NextSendAt(Writer.Paced) then
				Composed.NoteSendableAt(State, Text, Writer.Key)
			end
		end
	end
	local Sessions = State.Sessions
	for Text, Open in Sessions.Open do
		Composed.NoteSendableAt(State, Text, Open.Key)
	end
	local function IsIdleReadDue(Open: Session): boolean
		return Adoption.IsIdleReadDue(Server, Open, Clock)
	end
	for _, Text in Sorted.SortedDueTexts(Sessions.Open, IsIdleReadDue) do
		Adoption.IdleRead(Server, Sessions, Sessions.Open[Text], Clock, Commands)
	end
	Writing.RetryReads(State, Clock, Commands)
	Hearing.AnswerFlushesAtDeadline(State, Clock, Commands)
	Session.AnswerRefreshesDue(Sessions, Clock, Commands)
	Closing.ReleaseTimeOut(Sessions, Clock, Commands)
	Closing.EndClose(Server, Sessions, Composed.OpenCount(State), Clock, Commands)
	Writers.DropIdle(Server, Clock)
end

local function NextWake(State: State, Clock: number): number?
	local Kept = State.Wake
	table.clear(Kept.KeyAt)
	table.clear(Kept.KeyShedAt)
	table.clear(Kept.KeyOf)
	for _, Store in State.Server.Stores do
		for Text, Writer in Store.Writers do
			local WriterWake, WriterShedAt = WriterTimers(Writer, Store.Setup.Limits, Clock)
			KeepKey(Kept, Text, Writer.Key, WriterWake, WriterShedAt)
		end
	end
	for Text, Open in State.Sessions.Open do
		local Store = Cache.StoreOf(State.Server, Open.Key)
		local Wake = SessionWake(Open, Store.Writers[Text], Store.Setup.Limits, Clock)
		KeepKey(Kept, Text, Open.Key, EarliestAfter(Kept.KeyAt[Text], Wake, Clock), Kept.KeyShedAt[Text])
	end
	Kept.At = SoonestOf(Kept.KeyAt)
	Kept.ShedAt = SoonestOf(Kept.KeyShedAt)
	Kept.IsKnown = true
	table.clear(State.TimersMoved)
	return EarliestAfter(Kept.At, SharedWake(State, Clock), Clock)
end

local function RescanWake(State: State, Clock: number)
	local Kept = State.Wake
	local Soonest: number? = nil
	for Text, At in Kept.KeyAt do
		local KeyWake: number? = At
		if At <= Clock then
			KeyWake = KeyTimers(State, Text, Kept.KeyOf[Text], Clock)
			Kept.KeyAt[Text] = KeyWake
		end
		Soonest = EarlierOf(Soonest, KeyWake)
	end
	Kept.At = Soonest
end

local function FoldWake(State: State, Clock: number): number?
	local Kept = State.Wake
	if not Kept.IsKnown then
		return NextWake(State, Clock)
	end
	local IsWakeStale = false
	local IsShedStale = false
	for Text, Key in State.TimersMoved do
		local KeyWake, KeyShedAt = KeyTimers(State, Text, Key, Clock)
		Kept.At, IsWakeStale = FoldKey(Kept.At, IsWakeStale, Kept.KeyAt[Text], KeyWake)
		Kept.ShedAt, IsShedStale = FoldKey(Kept.ShedAt, IsShedStale, Kept.KeyShedAt[Text], KeyShedAt)
		KeepKey(Kept, Text, Key, KeyWake, KeyShedAt)
	end
	table.clear(State.TimersMoved)
	local At = Kept.At
	if IsWakeStale or (At ~= nil and At <= Clock) then
		RescanWake(State, Clock)
	end
	if IsShedStale then
		Kept.ShedAt = SoonestOf(Kept.KeyShedAt)
	end
	return EarliestAfter(Kept.At, SharedWake(State, Clock), Clock)
end

local function TrueWake(State: State, Clock: number): number?
	local Soonest = KeysWake(State, Clock)
	return EarliestAfter(Soonest, SharedWake(State, Clock), Clock)
end

return {
	ShedPastDeadline = ShedPastDeadline,
	OnClock = OnClock,
	NextWake = NextWake,
	FoldWake = FoldWake,
	TrueWake = TrueWake,
	KeysWake = KeysWake,
}
