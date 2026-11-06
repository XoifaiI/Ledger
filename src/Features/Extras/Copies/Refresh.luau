--!strict
--!optimize 2

--[=[
	Refresh: a key's copy holder's refresh (extras sheet E8, cuts sheet 8.6). Each check reads the key. While its
	lease is live, a holder pushes a newer state, or the lease's own q when it is RepushAge old or replica 0 says
	it reached too few replicas (Written below Replicas); it renews the lease on replica 0 when the read agrees
	with the lease; Copies/Push writes. A read behind the lease pushes nothing. A server holding no live lease
	pushes replica 0 alone.
	A failed write to replica 0 under a lease sends a cold read. If MemoryStore answers it, replica 0 is only hot:
	the count doubles once every replica of it was written, and the lease is kept for the next check. A failed write
	whose cold read fails, or one replica 0 refused, lets the lease go. A grown count outlives a push that did not
	reach every replica. A missing key loses replica 0's items and every replica this server knows of; an erased
	key's are found through replica 0's header (AdviseErased). OnClock owns the stop rule; a holder that stops is
	no longer served, so its remembered state moves to the small set (Reading/Showables). The holder's own read
	feeds this server's Follower of the key.

	OnClock looks only at the holders whose times in CopyTimes fell due, in the order of their key texts. A holder
	keeps a refresh time while NextAt is set and an expiry time at all times, put back at UsedAt plus CopyPushAge, or
	at the clock while a refresh or a local asker keeps it; so a holder out of use goes at the first Clock that would
	have found it before. NextAt gives the soonest refresh for the wake.

	Return type: A plain table of functions.
	Example usage:
		CopyRefresh.Start(State, Key, Clock, Commands)
--]=]

local Closing = require("../../../Record/Sessions/Closing")
local Composed = require("../../../Machine/Composed")
local CopyPush = require("./Push")
local CopyState = require("./State")
local DueTimes = require("../../../Machine/DueTimes")
local Events = require("../../../Machine/Events")
local Extras = require("../../../Record/Constants/Extras")
local ExtrasShapes = require("../Shapes")
local ExtrasState = require("../State")
local Items = require("./Items")
local Names = require("../../../Record/Encoding/Names")
local Numbers = require("../../../Record/Writing/Numbers")
local Reads = require("../../../Record/Reading/Reads")
local Reasons = require("../../../Record/Constants/Reasons")
local Replicas = require("./Replicas")
local Showables = require("../../../Record/Reading/Showables")
local Sorted = require("../../../Machine/Sorted")
local Spread = require("../Spread")
local Tick = require("./Tick")

type Answer = Events.Answer
type Command = Events.Command
type MemoryFetched = Events.MemoryFetched
type MemoryOutcome = Events.MemoryOutcome
type StoreKey = Names.StoreKey
type AdviceGet = CopyState.AdviceGet
type ColdRead = CopyState.ColdRead
type CopyHolder = CopyState.CopyHolder
type CopyLease = CopyState.CopyLease
type CopyPush = CopyState.CopyPush
type CopyRead = CopyState.CopyRead
type HeaderUpdate = CopyState.HeaderUpdate
type ItemRemove = CopyState.ItemRemove
type PartSet = CopyState.PartSet
type CopyHeader = ExtrasShapes.CopyHeader
type DueTimes<Item> = DueTimes.DueTimes<Item>
type State = Composed.State

local CheckEvery = Extras.CheckEvery
local CopyPushAge = Extras.CopyPushAge
local RepushAge = Extras.RepushAge
local RefreshEvery = Extras.RefreshEvery

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

local function RemoveItems(State: State, Key: StoreKey, Count: number, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	for _, Remove in Items.RemoveCommands(State.Server, Key, Count) do
		State.Extras.Purposes[Remove.RequestId] = ItemRemoval
		table.insert(Commands, Remove)
	end
end

local function RemoveGone(State: State, Key: StoreKey, Clock: number, Commands: { Command })
	local Holder = State.Extras.CopyHolders[Names.KeyText(Key)]
	local Lease = if Holder ~= nil then Holder.Lease else nil
	local Known = if Lease ~= nil then Lease.Replicas else 1
	RemoveItems(State, Key, math.max(Replicas.CountOf(State.Server, Key), Known), Clock, Commands)
end

local function AdviseErased(State: State, Key: StoreKey, Commands: { Command })
	local Encoding = State.Server.Encoding
	local HeaderKey = Items.HeaderKey(Encoding, Key, 0)
	local Purpose: AdviceGet = { Kind = "AdviceGet", Key = Key }
	local RequestId = ExtrasState.NewRequest(State.Server, State.Extras, Purpose)
	table.insert(Commands, Items.GetCommand(Encoding, HeaderKey, HeaderKey, RequestId))
end

local function IsMissing(Given: Answer): boolean
	return Given.Kind == "Failed" and Given.Reason == Reasons.Missing
end

local function IsLive(Lease: CopyLease, Clock: number): boolean
	return Clock < Lease.Until
end

local function IsPushDue(Lease: CopyLease, Q: number, Clock: number): boolean
	if Q ~= Lease.Q then
		return Q > Lease.Q
	end
	return Clock - Lease.PushedAt >= RepushAge or Lease.Written < Lease.Replicas
end

local function IsRenewDue(Lease: CopyLease, Clock: number): boolean
	return Lease.Until - Clock <= RefreshEvery
end

local function SendColdRead(State: State, Holder: CopyHolder, Commands: { Command })
	local Encoding = State.Server.Encoding
	local ColdKey = Replicas.ColdKeyOf(State.Server, Holder.Key)
	local Purpose: ColdRead = { Kind = "ColdRead", Holder = Holder }
	local RequestId = ExtrasState.NewRequest(State.Server, State.Extras, Purpose)
	table.insert(Commands, Items.GetCommand(Encoding, ColdKey, ColdKey, RequestId))
end

local function OnKeyShown(State: State, Next: CopyRead, Clock: number, Commands: { Command })
	local Holder = HolderOf(State, Next.Out.Key, Clock)
	if Next.Kind == "Handed" then
		if IsMissing(Next.Answer) then
			RemoveGone(State, Holder.Key, Clock, Commands)
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
	local Q = Next.Kept.Book.Writes
	if Lease == nil or not IsLive(Lease, Clock) then
		Holder.Lease = nil
		return CopyPush.Start(State, Holder, CopyPush.NewPlan(State, Next, Clock), 1, Clock, Commands)
	end
	if IsPushDue(Lease, Q, Clock) then
		return CopyPush.Start(State, Holder, CopyPush.NewPlan(State, Next, Clock), Lease.Replicas, Clock, Commands)
	end
	if Q == Lease.Q and IsRenewDue(Lease, Clock) then
		return CopyPush.SendRenewHeader(State, Holder, CopyPush.NewPlan(State, Next, Clock), Lease, Clock, Commands)
	end
	Holder.IsRefreshing = false
	RefreshAt(State, Holder, Clock + CheckEvery)
end

local function EndReplica(
	State: State,
	Holder: CopyHolder,
	Push: CopyPush,
	IsWritten: boolean,
	Clock: number,
	Commands: { Command }
)
	Push.Left -= 1
	Push.IsWhole = Push.IsWhole and IsWritten
	if Push.Left > 0 then
		return
	end
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return Abandon(Holder)
	end
	CopyPush.SendReplica(State, Holder, Push, 0, Clock, Commands)
end

local function Unwritten(
	State: State,
	Holder: CopyHolder,
	Push: CopyPush?,
	Replica: number,
	IsRefused: boolean,
	Clock: number,
	Commands: { Command }
)
	if Push ~= nil and Replica ~= 0 then
		return EndReplica(State, Holder, Push, false, Clock, Commands)
	end
	if IsRefused or Holder.Lease == nil or Closing.IsPastDeadline(State.Sessions, Clock) then
		return Abandon(Holder)
	end
	SendColdRead(State, Holder, Commands)
end

local function OnPartSet(State: State, Purpose: PartSet, Result: MemoryOutcome, Clock: number, Commands: { Command })
	local Holder = Purpose.Holder
	local Push = Purpose.Push
	if Result.Kind ~= "Ok" or Closing.IsPastDeadline(State.Sessions, Clock) then
		return Unwritten(State, Holder, Push, Purpose.Replica, false, Clock, Commands)
	end
	local NextIndex = Purpose.Index + 1
	if NextIndex < #Push.Plan.Pieces then
		return CopyPush.SendPart(State, Holder, Push, Purpose.Replica, NextIndex, Commands)
	end
	CopyPush.SendPushHeader(State, Holder, Push, Purpose.Replica, Clock, Commands)
end

local function MergedOf(Written: unknown, Carried: CopyHeader): CopyHeader
	local Decoded = Items.DecodeHeader(Written)
	if Decoded.Kind ~= "Header" then
		return Carried
	end
	return Decoded.Header
end

local function OnHeaderResult(
	State: State,
	Purpose: HeaderUpdate,
	Result: MemoryOutcome,
	Clock: number,
	Commands: { Command }
)
	local Holder = Purpose.Holder
	local Push = Purpose.Push
	if Result.Kind ~= "Ok" then
		return Unwritten(State, Holder, Push, Purpose.Replica, Result.Kind == "Nil", Clock, Commands)
	end
	if Push ~= nil and Purpose.Replica ~= 0 then
		return EndReplica(State, Holder, Push, true, Clock, Commands)
	end
	local Prior = Holder.Lease
	local Merged = MergedOf(Result.Value, Purpose.Header)
	Holder.IsRefreshing = false
	Holder.Lease = {
		Q = Merged.Q,
		PushedAt = Purpose.PushedAt,
		Until = Merged.HolderStamp.Until,
		Replicas = if Prior ~= nil then math.max(Prior.Replicas, Merged.Replicas) else Merged.Replicas,
		Written = Merged.Written,
	}
	RefreshAt(State, Holder, Clock + CheckEvery)
end

local function Grow(Holder: CopyHolder, Lease: CopyLease)
	if Lease.Written < Lease.Replicas then
		return
	end
	Holder.Lease = {
		Q = Lease.Q,
		PushedAt = Lease.PushedAt,
		Until = Lease.Until,
		Replicas = Spread.Grown(Lease.Replicas),
		Written = Lease.Written,
	}
end

local function OnColdRead(State: State, Purpose: ColdRead, Fetched: MemoryFetched, Clock: number)
	local Holder = Purpose.Holder
	local Lease = Holder.Lease
	if Fetched.Kind == "Failed" or Lease == nil then
		return Abandon(Holder)
	end
	Grow(Holder, Lease)
	Holder.IsRefreshing = false
	RefreshAt(State, Holder, Clock + CheckEvery)
end

local function OnAdviceHeader(
	State: State,
	Purpose: AdviceGet,
	Fetched: MemoryFetched,
	Clock: number,
	Commands: { Command }
)
	if Fetched.Kind ~= "Found" then
		return
	end
	local Decoded = Items.DecodeHeader(Fetched.Value)
	local Count = if Decoded.Kind == "Header" then Decoded.Header.Replicas else 1
	RemoveItems(State, Purpose.Key, Count, Clock, Commands)
end

return {
	Start = Start,
	OnClock = OnClock,
	NextAt = NextAt,
	OnKeyShown = OnKeyShown,
	OnPartSet = OnPartSet,
	OnHeaderResult = OnHeaderResult,
	OnColdRead = OnColdRead,
	RemoveGone = RemoveGone,
	AdviseErased = AdviseErased,
	OnAdviceHeader = OnAdviceHeader,
}
