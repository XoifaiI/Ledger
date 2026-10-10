--!strict
--!optimize 2

--[=[
	Refresh: the summary holder's refresh (sheet E5). Start reads every shard or part, owing a tidy on an old entry
	(E6); the last answer sends one MemoryStore update. An ok makes it the holder, refreshing RefreshEvery later; an
	err is a breaker miss. CanStart refuses before the server number, while out and closing. OnClock owns the stop
	rule.

	OnClock looks only at the holders whose times in SummaryTimes fell due, in the order they were made (Holders). A
	holder keeps a refresh time while NextAt is set and an expiry time at all times, put back at UsedAt plus
	SummaryExpiry, or at the clock while a refresh is out; so a holder out of use goes at the first Clock that would
	have found it before. Soonest gives the soonest refresh for the wake.

	Return type: A plain table of functions.
	Example usage:
		local Holder = ExtrasState.HolderOf(State.Extras, "Shop", "global", Total, Clock)
		if Refresh.CanStart(State, Holder) then Refresh.Start(State, Holder, Commands) end
--]=]

local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local DueTimes = require("../../DueTimes")
local Events = require("../../Events")
local Extras = require("../../Constants/Extras")
local ExtrasState = require("../State")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Pairs = require("./Pairs")
local Record = require("../../Constants/Record")
local Shapes = require("../../Shapes")
local Subject = require("./Subject")
local Summary = require("./Summary")
local Tidy = require("../Tidy")
local Value = require("../../Stored/Value")

type Command = Events.Command
type MemoryOutcome = Events.MemoryOutcome
type ReadOutcome = Events.ReadOutcome
type StoreKey = Names.StoreKey
type Kept = Value.Kept
type ServerState = Shapes.ServerState
type SummaryHolder = ExtrasState.SummaryHolder
type DueTimes<Item> = DueTimes.DueTimes<Item>
type TotalView = ExtrasState.TotalView
type State = Composed.State

local RefreshEvery = Extras.RefreshEvery
local SummaryExpiry = Extras.SummaryExpiry
local SummaryMapPrefix = Record.SummaryMapPrefix

local function SendUpdate(State: State, Holder: SummaryHolder, Commands: { Command })
	local Server = State.Server
	local Key = Summary.SummaryKey(Server.Encoding, Holder.Store, Holder.Scope, Holder.Total)
	local Update: Command = {
		Kind = "MemoryUpdate",
		RequestId = ExtrasState.NewRequest(Server, State.Extras, { Kind = "SummaryUpdate", Holder = Holder }),
		Map = Summary.MapOf(Server.Encoding, SummaryMapPrefix, Key),
		Key = Key,
		Item = Subject.TransformFor(State, Holder, Numbers.ServerNumberOf(Server)),
		Expiry = SummaryExpiry,
	}
	Holder.Out += 1
	table.insert(Commands, Update)
end

local function CanStart(State: State, Holder: SummaryHolder): boolean
	return State.Server.ServerNumber ~= nil and Holder.Out == 0 and State.Sessions.Shutdown == nil
end

local function Start(State: State, Holder: SummaryHolder, Commands: { Command })
	local Server = State.Server
	for Index = 0, Holder.Total.KeyCount - 1 do
		local Purpose: ExtrasState.Purpose = { Kind = "RefreshRead", Holder = Holder, Index = Index }
		local Get: Command = {
			Kind = "Get",
			RequestId = ExtrasState.NewRequest(Server, State.Extras, Purpose),
			Target = Subject.KeyOf(Holder, Index),
		}
		Holder.Out += 1
		table.insert(Commands, Get)
	end
end

local function OnKeyRead(
	State: State,
	Holder: SummaryHolder,
	Index: number,
	Fetched: ReadOutcome,
	Fraction: number,
	Clock: number,
	Commands: { Command }
)
	local Kept = Subject.LearnRead(State, Holder, Index, Fetched, Clock)
	local Key = Subject.KeyOf(Holder, Index)
	if Kept ~= nil and Tidy.IsDue(Kept, Numbers.EntryFor(State.Server, Key), Clock) then
		Tidy.Owe(State, Key, Clock, Fraction)
	end
	Holder.Out -= 1
	if Holder.Out == 0 and not Closing.IsPastDeadline(State.Sessions, Clock) then
		SendUpdate(State, Holder, Commands)
	end
end

local function OnResult(State: State, Holder: SummaryHolder, Result: MemoryOutcome, Clock: number)
	Holder.Out -= 1
	local View = Subject.ViewOf(State, Holder)
	if Result.Kind == "Err" then
		Pairs.NoteMiss(View, Clock)
	else
		Pairs.NoteHit(View)
	end
	if Result.Kind ~= "Ok" then
		Holder.NextAt = nil
		return
	end
	local At = Clock + RefreshEvery
	Holder.NextAt = At
	DueTimes.Add(State.Extras.SummaryTimes.Refreshes, Holder, At)
end

local function NextAt(Holder: SummaryHolder): number?
	if Holder.Out > 0 then
		return nil
	end
	return Holder.NextAt
end

local function IsDue(Holder: SummaryHolder, Clock: number): boolean
	local At = NextAt(Holder)
	return At ~= nil and Clock >= At
end

local function IsOutOfUse(Holder: SummaryHolder, Clock: number): boolean
	return Holder.Out == 0 and Clock - Holder.UsedAt >= SummaryExpiry
end

local function TakeDueHolders(
	Times: DueTimes<SummaryHolder>,
	Clock: number,
	Due: { [SummaryHolder]: true }
): { [SummaryHolder]: true }
	local Taken: { [SummaryHolder]: true } = {}
	for _, Holder in DueTimes.TakeDue(Times, Clock) do
		Taken[Holder] = true
		Due[Holder] = true
	end
	return Taken
end

local function InHolderOrder(State: State, Due: { [SummaryHolder]: true }): { SummaryHolder }
	local Places: { [SummaryHolder]: number } = {}
	local Ordered: { SummaryHolder } = {}
	for Holder in Due do
		local Place = table.find(State.Extras.Holders, Holder)
		if Place ~= nil then
			Places[Holder] = Place
			table.insert(Ordered, Holder)
		end
	end
	table.sort(Ordered, function(Holder: SummaryHolder, Other: SummaryHolder): boolean
		return Places[Holder] < Places[Other]
	end)
	return Ordered
end

local function OnClock(State: State, Clock: number, Commands: { Command })
	local Times = State.Extras.SummaryTimes
	local Due: { [SummaryHolder]: true } = {}
	local Refreshing = TakeDueHolders(Times.Refreshes, Clock, Due)
	local Expiring = TakeDueHolders(Times.Expiries, Clock, Due)
	for _, Holder in InHolderOrder(State, Due) do
		if IsOutOfUse(Holder, Clock) then
			ExtrasState.DropHolder(State.Extras, Holder)
			continue
		end
		if IsDue(Holder, Clock) and CanStart(State, Holder) then
			Start(State, Holder, Commands)
		end
		local At = NextAt(Holder)
		if Refreshing[Holder] and At ~= nil and Clock >= At then
			DueTimes.Add(Times.Refreshes, Holder, At)
		end
		if Expiring[Holder] then
			DueTimes.Add(Times.Expiries, Holder, math.max(Holder.UsedAt + SummaryExpiry, Clock))
		end
	end
end

local function IsRefreshAt(Held: ExtrasState.ExtrasState, Holder: SummaryHolder, At: number): boolean
	return NextAt(Holder) == At and ExtrasState.IsHeld(Held, Holder)
end

local function Soonest(State: State, Clock: number): number?
	return DueTimes.Soonest(State.Extras.SummaryTimes.Refreshes, Clock, State.Extras, IsRefreshAt)
end

return {
	CanStart = CanStart,
	Start = Start,
	SendUpdate = SendUpdate,
	OnKeyRead = OnKeyRead,
	OnResult = OnResult,
	NextAt = NextAt,
	IsDue = IsDue,
	OnClock = OnClock,
	Soonest = Soonest,
}
