--!strict
--!optimize 2

--[=[
	Refresh: a key's copy holder's refresh (extras sheet E8, cuts sheet 8.6). It pushes a newer state or one
	CopyPushAge old, or renews its lease. On an equal q a push at another level writes its header whole; a renew keeps
	the held level, floor and body. A missing or erased key loses its items. OnClock owns the stop rule; a holder
	that stops is no longer served, so its remembered state moves to the small set (Reading/Showables). The holder's
	own read feeds this server's Follower of the key (extras 5.3), whose header then shows no newer q.

	OnClock looks only at the holders whose times in CopyTimes fell due, in the order of their key texts. A holder
	keeps a refresh time while NextAt is set and an expiry time at all times, put back at UsedAt plus CopyPushAge, or
	at the clock while a refresh or a local asker keeps it; so a holder out of use goes at the first Clock that would
	have found it before. NextAt gives the soonest refresh for the wake.

	Return type: A plain table of functions.
	Example usage:
		CopyRefresh.Start(State, Key, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local CopyState = require("./State")
local DueTimes = require("../../DueTimes")
local Events = require("../../Events")
local Extras = require("../../Constants/Extras")
local ExtrasShapes = require("../Shapes")
local ExtrasState = require("../State")
local Items = require("./Items")
local Json = require("../../Encoding/Json")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Reads = require("../../Reading/Reads")
local Reasons = require("../../Constants/Reasons")
local Shapes = require("../../Shapes")
local Showables = require("../../Reading/Showables")
local Sorted = require("../../Sorted")
local Tick = require("./Tick")
local View = require("../../Reading/View")

type Answer = Events.Answer
type Command = Events.Command
type MemoryFetched = Events.MemoryFetched
type MemoryOutcome = Events.MemoryOutcome
type StoreKey = Names.StoreKey
type AdviceGet = CopyState.AdviceGet
type CopyHolder = CopyState.CopyHolder
type CopyLease = CopyState.CopyLease
type CopyPlan = CopyState.CopyPlan
type CopyRead = CopyState.CopyRead
type HeaderUpdate = CopyState.HeaderUpdate
type ItemRemove = CopyState.ItemRemove
type PartSet = CopyState.PartSet
type CopyBody = ExtrasShapes.CopyBody
type CopyHeader = ExtrasShapes.CopyHeader
type HolderStamp = ExtrasShapes.HolderStamp
type Opened = Reads.Opened
type DueTimes<Item> = DueTimes.DueTimes<Item>
type ServerState = Shapes.ServerState
type State = Composed.State

local CheckEvery = Extras.CheckEvery
local CopyExpiry = Extras.CopyExpiry
local CopyPushAge = Extras.CopyPushAge
local HolderSpan = Extras.HolderSpan
local RefreshEvery = Extras.RefreshEvery

local HeaderWrite = {
	Push = "Push" :: "Push",
	Renew = "Renew" :: "Renew",
}

type HeaderWrite = keyof<typeof(HeaderWrite)>

local CopyWant: Reads.Want = table.freeze({ Kind = "Copy" :: "Copy" })
local ItemRemoval: ItemRemove = table.freeze({ Kind = "ItemRemove" :: "ItemRemove" })

local function CanStart(State: State, Holder: CopyHolder): boolean
	return State.Server.ServerNumber ~= nil and not Holder.IsRefreshing and State.Sessions.Shutdown == nil
end

local function StartRefresh(State: State, Holder: CopyHolder, Clock: number, Commands: { Command })
	if not CanStart(State, Holder) then
		return
	end
	local Server = State.Server
	local Call = { CallId = Numbers.NewHelperId(Server), Key = Holder.Key }
	local Out = Reads.StartWant(Server, Call, CopyWant, Clock, Commands)
	State.Reads[Out.RequestId] = Out
	Holder.IsRefreshing = true
	Holder.NextAt = nil
end

local function HolderOf(State: State, Key: StoreKey, Clock: number): CopyHolder
	local Text = Names.KeyText(Key)
	local Holders = State.Extras.CopyHolders
	local Held = Holders[Text]
	if Held ~= nil then
		return Held
	end
	local Made = CopyState.NewCopyHolder(Key, Text, Clock)
	Holders[Text] = Made
	DueTimes.Add(State.Extras.CopyTimes.Expiries, Text, Clock + CopyPushAge)
	Showables.Serve(State.Server, Key)
	return Made
end

local function RefreshAt(State: State, Holder: CopyHolder, At: number)
	Holder.NextAt = At
	DueTimes.Add(State.Extras.CopyTimes.Refreshes, Holder.Text, At)
end

local function Start(State: State, Key: StoreKey, Clock: number, Commands: { Command })
	StartRefresh(State, HolderOf(State, Key, Clock), Clock, Commands)
end

local function IsKeyAskedHere(State: State, Key: StoreKey): boolean
	local Text = Names.KeyText(Key)
	if State.Extras.Followers[Text] ~= nil then
		return true
	end
	for _, Work in State.Extras.Peeks do
		if Names.KeyText(Work.Follower.Key) == Text then
			return true
		end
	end
	return false
end

local function IsOutOfUse(State: State, Holder: CopyHolder, Clock: number): boolean
	if Holder.IsRefreshing or Clock - Holder.UsedAt < CopyPushAge then
		return false
	end
	return not IsKeyAskedHere(State, Holder.Key)
end

local function TakeDueTexts(Times: DueTimes<string>, Clock: number, Due: { [string]: true }): { [string]: true }
	local Taken: { [string]: true } = {}
	for _, Text in DueTimes.TakeDue(Times, Clock) do
		Taken[Text] = true
		Due[Text] = true
	end
	return Taken
end

local function OnClock(State: State, Clock: number, Commands: { Command })
	local Holders = State.Extras.CopyHolders
	local Times = State.Extras.CopyTimes
	local Due: { [string]: true } = {}
	local Refreshing = TakeDueTexts(Times.Refreshes, Clock, Due)
	local Expiring = TakeDueTexts(Times.Expiries, Clock, Due)
	for _, Text in Sorted.SortedTexts(Due) do
		local Holder = Holders[Text]
		if Holder == nil then
			continue
		end
		if IsOutOfUse(State, Holder, Clock) then
			Holders[Text] = nil
			Showables.Unserve(State.Server, Holder.Key, Composed.ServedOf(State))
			continue
		end
		local At = Holder.NextAt
		if At ~= nil and Clock >= At then
			StartRefresh(State, Holder, Clock, Commands)
		end
		if Refreshing[Text] and Holder.NextAt ~= nil and Clock >= Holder.NextAt then
			DueTimes.Add(Times.Refreshes, Text, Holder.NextAt)
		end
		if Expiring[Text] then
			DueTimes.Add(Times.Expiries, Text, math.max(Holder.UsedAt + CopyPushAge, Clock))
		end
	end
end

local function IsRefreshAt(Holders: { [string]: CopyHolder }, Text: string, At: number): boolean
	local Holder = Holders[Text]
	return Holder ~= nil and Holder.NextAt == At
end

local function NextAt(State: State, Clock: number): number?
	return DueTimes.Soonest(State.Extras.CopyTimes.Refreshes, Clock, State.Extras.CopyHolders, IsRefreshAt)
end

local function Abandon(Holder: CopyHolder)
	Holder.IsRefreshing = false
	Holder.Lease = nil
	Holder.NextAt = nil
end

local function TakesCarriedLevel(Write: HeaderWrite, Held: CopyHeader, Carried: CopyHeader): boolean
	return Write == HeaderWrite.Push and Carried.Level ~= Held.Level
end

local function HeaderTransform(Carried: CopyHeader, Write: HeaderWrite): (Current: unknown, Clock: number) -> unknown?
	return function(Current: unknown, Clock: number): unknown?
		local Decoded = Items.DecodeHeader(Current)
		if Decoded.Kind == "Behind" then
			return nil
		end
		if Decoded.Kind == "Header" then
			local Held = Decoded.Header
			if Held.HolderStamp.HolderNumber ~= Carried.HolderStamp.HolderNumber and Held.HolderStamp.Until > Clock then
				return nil
			end
			if Carried.Q < Held.Q then
				return nil
			end
			if Carried.Q == Held.Q and not TakesCarriedLevel(Write, Held, Carried) then
				local Renewed: CopyHeader = {
					Q = Held.Q,
					Level = Held.Level,
					Floor = Held.Floor,
					Incarnation = Held.Incarnation,
					HolderStamp = Carried.HolderStamp,
					Body = Held.Body,
				}
				return Items.EncodeHeader(Renewed)
			end
		end
		return Items.EncodeHeader(Carried)
	end
end

local function NewHolderStamp(Server: ServerState, Clock: number): HolderStamp
	return { HolderNumber = Numbers.ServerNumberOf(Server), Until = Clock + HolderSpan, At = Clock }
end

local function HeaderOf(Plan: CopyPlan, Stamped: HolderStamp): CopyHeader
	return {
		Q = Plan.Q,
		Level = Plan.Level,
		Floor = Plan.Floor,
		Incarnation = Plan.Incarnation,
		HolderStamp = Stamped,
		Body = Plan.Body,
	}
end

local function PlanWith(Whole: CopyPlan, Body: CopyBody, Pieces: { string }): CopyPlan
	return {
		Q = Whole.Q,
		Level = Whole.Level,
		Floor = Whole.Floor,
		Incarnation = Whole.Incarnation,
		Body = Body,
		Pieces = Pieces,
	}
end

local function NewPlan(State: State, Opened: Opened, Clock: number): CopyPlan
	local Server = State.Server
	local Book = Opened.Kept.Book
	local Build = Cache.StoreOf(Server, Opened.Out.Key).Setup.Build
	local Level = math.max(Book.Level, Build.MigrationCount)
	local Whole: CopyPlan = {
		Q = Book.Writes,
		Level = Level,
		Floor = View.MigratedFloor(Build, Book.Level, Book.Floor),
		Incarnation = Book.Identity or false,
		Body = { Kind = "State", State = Opened.Viewed },
		Pieces = {},
	}
	if Items.Fits(HeaderOf(Whole, NewHolderStamp(Server, Clock))) then
		return Whole
	end
	local Pieces = Items.CutPieces(Json.CanonicalJson(Opened.Viewed), Whole.Q, Level)
	if Pieces == nil then
		return PlanWith(Whole, { Kind = "Big" }, {})
	end
	return PlanWith(Whole, { Kind = "Parts", Count = #Pieces }, Pieces)
end

local function SendHeader(
	State: State,
	Holder: CopyHolder,
	Plan: CopyPlan,
	Write: HeaderWrite,
	PushedAt: number,
	Clock: number,
	Commands: { Command }
)
	local Encoding = State.Server.Encoding
	local Key = Items.HeaderKey(Encoding, Holder.Key)
	local Carried = HeaderOf(Plan, NewHolderStamp(State.Server, Clock))
	local Purpose: HeaderUpdate = { Kind = "HeaderUpdate", Holder = Holder, Header = Carried, PushedAt = PushedAt }
	local Update: Command = {
		Kind = "MemoryUpdate",
		RequestId = ExtrasState.NewRequest(State.Server, State.Extras, Purpose),
		Map = Items.CopyMap(Encoding, Key),
		Key = Key,
		Item = HeaderTransform(Carried, Write),
		Expiry = CopyExpiry,
	}
	table.insert(Commands, Update)
end

local function SendPart(State: State, Holder: CopyHolder, Plan: CopyPlan, Index: number, Commands: { Command })
	local Encoding = State.Server.Encoding
	local HeaderKey = Items.HeaderKey(Encoding, Holder.Key)
	local Purpose: PartSet = { Kind = "PartSet", Holder = Holder, Plan = Plan, Index = Index }
	local Set: Command = {
		Kind = "MemorySet",
		RequestId = ExtrasState.NewRequest(State.Server, State.Extras, Purpose),
		Map = Items.CopyMap(Encoding, HeaderKey),
		Key = Items.PartKey(HeaderKey, Plan.Q, Index),
		Item = Items.EncodePart({ Q = Plan.Q, Level = Plan.Level, Piece = Plan.Pieces[Index + 1] }),
		Expiry = CopyExpiry,
	}
	table.insert(Commands, Set)
end

local function RemoveItems(State: State, Key: StoreKey, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	for _, Remove in Items.RemoveCommands(State.Server, Key) do
		State.Extras.Purposes[Remove.RequestId] = ItemRemoval
		table.insert(Commands, Remove)
	end
end

local function IsMissing(Given: Answer): boolean
	return Given.Kind == "Failed" and Given.Reason == Reasons.Missing
end

local function IsPushDue(Lease: CopyLease, Q: number, Clock: number): boolean
	return Q > Lease.Q or Clock - Lease.PushedAt >= CopyPushAge
end

local function IsRenewDue(Lease: CopyLease, Clock: number): boolean
	return Lease.Until - Clock <= RefreshEvery
end

local function Push(State: State, Holder: CopyHolder, Plan: CopyPlan, Clock: number, Commands: { Command })
	if #Plan.Pieces == 0 then
		return SendHeader(State, Holder, Plan, HeaderWrite.Push, Clock, Clock, Commands)
	end
	SendPart(State, Holder, Plan, 0, Commands)
end

local function OnKeyShown(State: State, Next: CopyRead, Clock: number, Commands: { Command })
	local Holder = HolderOf(State, Next.Out.Key, Clock)
	if Next.Kind == "Handed" then
		if IsMissing(Next.Answer) then
			RemoveItems(State, Holder.Key, Clock, Commands)
		end
		return Abandon(Holder)
	end
	if State.Sessions.Shutdown ~= nil then
		return Abandon(Holder)
	end
	local Follower = State.Extras.Followers[Holder.Text]
	if Follower ~= nil then
		Tick.GiveRising(State, Follower, Next.Kept.Book.Writes, Next.Viewed, Commands)
	end
	local Lease = Holder.Lease
	if Lease == nil or IsPushDue(Lease, Next.Kept.Book.Writes, Clock) then
		return Push(State, Holder, NewPlan(State, Next, Clock), Clock, Commands)
	end
	if IsRenewDue(Lease, Clock) then
		local Plan = NewPlan(State, Next, Clock)
		return SendHeader(State, Holder, Plan, HeaderWrite.Renew, Lease.PushedAt, Clock, Commands)
	end
	Holder.IsRefreshing = false
	RefreshAt(State, Holder, Clock + CheckEvery)
end

local function OnPartSet(State: State, Purpose: PartSet, Result: MemoryOutcome, Clock: number, Commands: { Command })
	local Holder = Purpose.Holder
	if Result.Kind ~= "Ok" or Closing.IsPastDeadline(State.Sessions, Clock) then
		return Abandon(Holder)
	end
	local NextIndex = Purpose.Index + 1
	if NextIndex < #Purpose.Plan.Pieces then
		return SendPart(State, Holder, Purpose.Plan, NextIndex, Commands)
	end
	SendHeader(State, Holder, Purpose.Plan, HeaderWrite.Push, Clock, Clock, Commands)
end

local function OnHeaderResult(State: State, Purpose: HeaderUpdate, Result: MemoryOutcome, Clock: number)
	local Holder = Purpose.Holder
	if Result.Kind ~= "Ok" then
		return Abandon(Holder)
	end
	local Written = Purpose.Header
	Holder.IsRefreshing = false
	Holder.Lease = { Q = Written.Q, PushedAt = Purpose.PushedAt, Until = Written.HolderStamp.Until }
	RefreshAt(State, Holder, Clock + CheckEvery)
end

local function AdviseErased(State: State, Key: StoreKey, Commands: { Command })
	local Encoding = State.Server.Encoding
	local HeaderKey = Items.HeaderKey(Encoding, Key)
	local Purpose: AdviceGet = { Kind = "AdviceGet", Key = Key }
	local RequestId = ExtrasState.NewRequest(State.Server, State.Extras, Purpose)
	table.insert(Commands, Items.GetCommand(Encoding, HeaderKey, HeaderKey, RequestId))
end

local function OnAdviceHeader(
	State: State,
	Purpose: AdviceGet,
	Fetched: MemoryFetched,
	Clock: number,
	Commands: { Command }
)
	if Fetched.Kind == "Found" then
		RemoveItems(State, Purpose.Key, Clock, Commands)
	end
end

return {
	Start = Start,
	OnClock = OnClock,
	NextAt = NextAt,
	HeaderTransform = HeaderTransform,
	OnKeyShown = OnKeyShown,
	OnPartSet = OnPartSet,
	OnHeaderResult = OnHeaderResult,
	RemoveItems = RemoveItems,
	AdviseErased = AdviseErased,
	OnAdviceHeader = OnAdviceHeader,
}
