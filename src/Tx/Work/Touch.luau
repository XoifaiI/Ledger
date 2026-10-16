--!strict
--!optimize 2

--[=[
	Touch: what a server does after its own answer that showed work left on a key (transaction sheets 18.1, 18.2).

	A touch's write of ends is no touch. The key's helper finishes a due gate. For a session's Load or idle read, only
	a standing mark is due at the top level (5.1). From the close deadline it starts nothing.

	Return type: A plain table of functions.
	Example usage:
		Touch.AfterEvent(State, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Ends = require("../Legs/Ends")
local Events = require("../../Events")
local Format = require("../../Encoding/Format")
local HashInputs = require("../../Encoding/HashInputs")
local Help = require("./Help")
local Helper = require("../../Cuts/Call/Helper")
local JudgingShapes = require("../../Judging/Shapes")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Rides = require("../Rides")
local Seal = require("../../Stored/Items/Seal")
local Sending = require("../../Writing/Sending")
local Shapes = require("../../Shapes")
local Sorted = require("../../Sorted")
local TxShapes = require("../Shapes")
local TxState = require("../State")
local Unreachable = require("./Unreachable")
local Verify = require("./Verify")
local Work = require("../../Stored/Items/Work")

type Command = Events.Command
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type Name = Names.Name
type StoreKey = Names.StoreKey
type End = TxShapes.End
type Finished = Rides.Finished
type EndWorkReport = JudgingShapes.EndWorkReport
type Limits = Shapes.Limits
type Request = Shapes.Request
type ServerState = Shapes.ServerState
type Gate = Seal.Gate
type Mark = Work.Mark
type MarkOpening = Work.MarkOpening
type StandingMark = Work.StandingMark
type Writer = Format.Writer
type State = Composed.State
type Purpose = TxState.Purpose
type Waiter = TxState.Waiter
type TouchWaiter = TxState.TouchWaiter
type TouchWake = TxState.TouchWake
type WorkWaiter = TxState.WorkWaiter

type DueRule = (Server: ServerState, Limits: Limits, Item: Mark, First: number) -> number

local NameStartBytes = 64
local GateTag = "Gate:"
local StampSeparator = ":"

local function LimitsOf(Server: ServerState, Key: StoreKey): Limits
	return Cache.StoreOf(Server, Key).Setup.Limits
end

local function SeenText(Key: StoreKey, Written: Writer, Stamp: number): string
	return Names.KeyText(Key) .. Format.ToString(Written) .. StampSeparator .. tostring(Stamp)
end

local function MarkSeenText(Key: StoreKey, Opening: MarkOpening): string
	local Out = Format.NewWriter(NameStartBytes)
	local Part = Opening.Part
	if Part == nil then
		Names.WriteName(Out, Opening.Name)
	else
		Names.WriteSubName(Out, Opening.Name, Part)
	end
	return SeenText(Key, Out, Opening.Stamp)
end

local function GateSeenText(Key: StoreKey, KeyGate: Gate): string
	local Out = Format.NewWriter(NameStartBytes)
	Names.WriteName(Out, KeyGate.Name)
	return GateTag .. SeenText(Key, Out, KeyGate.PlacedAt)
end

local function IsSameKey(Left: StoreKey, Right: StoreKey): boolean
	return Left.Key == Right.Key and Left.Scope == Right.Scope and Left.Store == Right.Store
end

local function IsSameWork(For: Waiter, Work: WorkWaiter): boolean
	if Work.Kind == "Touch" then
		return For.Kind == "Touch" and IsSameKey(For.Key, Work.Key)
	end
	return For.Kind == "Resettle" and For.CallId == Work.CallId
end

local function Level(Server: ServerState, Limits: Limits, Name: Name): number
	local Input = HashInputs.TouchInput(Numbers.ServerNumberOf(Server), Name)
	return math.min(HashInputs.TouchLevel(HashInputs.Hash(Server.Encoding, Input)), Limits.TouchLevels)
end

local function FirstSeenAs(State: State, Text: string, Clock: number): number
	local Tx = State.Tx
	local First = Tx.FirstSeen[Text]
	if First ~= nil then
		return First
	end
	local Oldest = Tx.SeenOrder[Tx.SeenNext]
	if Oldest ~= nil then
		Tx.FirstSeen[Oldest] = nil
	end
	Tx.SeenOrder[Tx.SeenNext] = Text
	Tx.SeenNext = Tx.SeenNext % Cache.ServerLimits(State.Server).SentNamesKept + 1
	Tx.FirstSeen[Text] = Clock
	return Clock
end

local function NoteSeen(State: State, Key: StoreKey, Item: Mark, Clock: number): number
	return FirstSeenAs(State, MarkSeenText(Key, Item.Opening), Clock)
end

local function DueAtLevel(Limits: Limits, TouchLevel: number, Stamp: number, First: number): number
	local Wait = (Limits.TouchLevels - TouchLevel) * Limits.TouchStep
	return math.max(Stamp + Limits.SettleAge + Wait, First + Wait)
end

local function SettledDueAt(Server: ServerState, Limits: Limits, Name: Name, Stamp: number, First: number): number
	return DueAtLevel(Limits, Level(Server, Limits, Name), Stamp, First)
end

local function NoteGateDueAt(State: State, Limits: Limits, Key: StoreKey, KeyGate: Gate, Clock: number): number
	local First = FirstSeenAs(State, GateSeenText(Key, KeyGate), Clock)
	return SettledDueAt(State.Server, Limits, KeyGate.Name, KeyGate.PlacedAt, First)
end

local function DueAt(Server: ServerState, Limits: Limits, Item: Mark, First: number): number
	local Due = SettledDueAt(Server, Limits, Item.Opening.Name, Item.Opening.Stamp, First)
	if Item.Kind == "Pinned" then
		return math.max(Due, Item.Opening.Stamp + Limits.PinEvictAge)
	end
	return Due
end

local function SessionDueAt(Server: ServerState, Limits: Limits, Item: Mark, First: number): number
	if Item.Kind == "Pinned" then
		return DueAt(Server, Limits, Item, First)
	end
	return DueAtLevel(Limits, Limits.TouchLevels, Item.Opening.Stamp, First)
end

local function DueBy(
	Rule: DueRule,
	Server: ServerState,
	Key: StoreKey,
	Listed: { Mark },
	FirstSeen: { [Mark]: number },
	Clock: number
): { Mark }
	local Limits = LimitsOf(Server, Key)
	local Due: { Mark } = {}
	for _, Item in Listed do
		if Rule(Server, Limits, Item, FirstSeen[Item]) <= Clock then
			table.insert(Due, Item)
		end
	end
	return Due
end

local function ItemsDue(
	Server: ServerState,
	Key: StoreKey,
	Listed: { Mark },
	FirstSeen: { [Mark]: number },
	Clock: number
): { Mark }
	return DueBy(DueAt, Server, Key, Listed, FirstSeen, Clock)
end

local function NextDue(
	Server: ServerState,
	Key: StoreKey,
	Listed: { Mark },
	FirstSeen: { [Mark]: number },
	Clock: number
): number?
	local Limits = LimitsOf(Server, Key)
	local Soonest: number? = nil
	for _, Item in Listed do
		Soonest = Composed.EarliestAfter(Soonest, DueAt(Server, Limits, Item, FirstSeen[Item]), Clock)
	end
	return Soonest
end

local function IsWorking(State: State, For: WorkWaiter): boolean
	local Tx = State.Tx
	for _, Helping in Tx.Helps do
		if IsSameWork(Helping.For, For) then
			return true
		end
	end
	for _, Verifying in Tx.Verifies do
		if Verifying.Left > 0 and IsSameWork(Verifying.For, For) then
			return true
		end
	end
	return For.Kind == "Touch" and Helper.IsFinishing(State.Cuts, For.Key)
end

local function IsTouching(State: State, Key: StoreKey): boolean
	local Tx = State.Tx
	local Touching: TouchWaiter = { Kind = "Touch", Key = Key }
	if IsWorking(State, Touching) then
		return true
	end
	for _, Purpose in Tx.Purposes do
		if Purpose.Kind == "TouchWrite" and IsSameKey(Purpose.Key, Key) then
			return true
		end
	end
	for _, Resettling in Tx.Resettles do
		if IsSameKey(Resettling.Key, Key) then
			return true
		end
	end
	return false
end

local function TouchItem(State: State, For: WorkWaiter, Key: StoreKey, Item: Mark, Clock: number, Commands: { Command })
	if Item.Kind == "Pinned" then
		Verify.Start(State, For, Key, { Item }, Clock, Commands)
		return
	end
	local Blocked: EndWorkReport = { Kind = "Blocked", Marks = { Item } }
	Help.StartHelp(State, For, Key, Blocked, Clock, Commands)
end

local function SendEnds(State: State, Key: StoreKey, Request: Request, Purpose: Purpose, Commands: { Command })
	local Update: Command = {
		Kind = "Update",
		RequestId = TxState.NewRequest(State.Server, State.Tx, Purpose),
		Target = Key,
		Request = Request,
	}
	table.insert(Commands, Update)
end

local function LandTouch(State: State, Key: StoreKey, Clock: number, Commands: { Command })
	local Carried = Rides.TakeFor(State.Server, Key, Clock, { Kind = "Touch", Key = Key })
	if #Carried == 0 then
		return
	end
	local Purpose: Purpose = { Kind = "TouchWrite", Key = Key, Carried = Carried }
	SendEnds(State, Key, Ends.EndsRequest(Carried), Purpose, Commands)
end

local function ActOnKey(State: State, Key: StoreKey, Rule: DueRule, Clock: number, Commands: { Command })
	local Server = State.Server
	local Tx = State.Tx
	local Text = Names.KeyText(Key)
	local Entry = Cache.FindEntry(Server, Key)
	if Entry == nil or Entry.Work == nil then
		Tx.TouchAt[Text] = nil
		return
	end
	local Listed = Entry.Work
	Unreachable.WarnOnce(State, Key, Listed, Commands)
	local Limits = LimitsOf(Server, Key)
	local FirstSeen: { [Mark]: number } = {}
	for _, Item in Listed do
		FirstSeen[Item] = NoteSeen(State, Key, Item, Clock)
	end
	local Held = Entry.Gate
	local GateAt = if Held == nil then nil else NoteGateDueAt(State, Limits, Key, Held, Clock)
	local DueGate = if GateAt ~= nil and GateAt <= Clock and not Helper.HasCutCall(State.Cuts, Key) then Held else nil
	local Due = DueBy(Rule, Server, Key, Listed, FirstSeen, Clock)
	local HasDue = #Due > 0 or DueGate ~= nil
	if HasDue and IsTouching(State, Key) then
		Tx.TouchAt[Text] = { Key = Key, At = Clock }
		return
	end
	if HasDue then
		local For: TouchWaiter = { Kind = "Touch", Key = Key }
		for _, Item in Due do
			TouchItem(State, For, Key, Item, Clock, Commands)
		end
		if DueGate ~= nil then
			Helper.FinishGate(State, Key, DueGate, For, Clock, Commands)
		end
		if not IsWorking(State, For) then
			LandTouch(State, Key, Clock, Commands)
		end
	end
	local At = Composed.EarliestAfter(NextDue(Server, Key, Listed, FirstSeen, Clock), GateAt, Clock)
	Tx.TouchAt[Text] = if At == nil then nil else { Key = Key, At = At }
end

local function MaySessionAct(State: State, Key: StoreKey, Clock: number): boolean
	if State.Server.ServerNumber == nil or Closing.IsPastDeadline(State.Sessions, Clock) then
		return false
	end
	return not IsTouching(State, Key)
end

local function ActForSession(State: State, Key: StoreKey, Clock: number, Commands: { Command })
	if not MaySessionAct(State, Key, Clock) then
		return
	end
	State.Server.WorkSeen[Names.KeyText(Key)] = nil
	ActOnKey(State, Key, SessionDueAt, Clock, Commands)
end

local function IsDueForSession(State: State, Key: StoreKey, Item: StandingMark, Clock: number): boolean
	if not MaySessionAct(State, Key, Clock) then
		return false
	end
	local Server = State.Server
	return SessionDueAt(Server, LimitsOf(Server, Key), Item, NoteSeen(State, Key, Item, Clock)) <= Clock
end

local function ReadDueKeys(State: State, Clock: number, Commands: { Command })
	local Tx = State.Tx
	local function IsDue(Wake: TouchWake): boolean
		return Wake.At <= Clock
	end
	for _, Text in Sorted.SortedDueTexts(Tx.TouchAt, IsDue) do
		local Wake = Tx.TouchAt[Text]
		if IsTouching(State, Wake.Key) then
			continue
		end
		Tx.TouchAt[Text] = nil
		local Purpose: Purpose = { Kind = "TouchRead", Key = Wake.Key }
		local Get: Command =
			{ Kind = "Get", RequestId = TxState.NewRequest(State.Server, Tx, Purpose), Target = Wake.Key }
		table.insert(Commands, Get)
	end
end

local function AfterEvent(State: State, Clock: number, Commands: { Command })
	local Server = State.Server
	Rides.Expire(Server, Clock)
	if Server.ServerNumber == nil then
		return
	end
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Learned = Server.WorkSeen
	Server.WorkSeen = {}
	for _, Text in Sorted.SortedTexts(Learned) do
		ActOnKey(State, Learned[Text], DueAt, Clock, Commands)
	end
	ReadDueKeys(State, Clock, Commands)
end

local function NextWake(State: State, Clock: number): number?
	local Soonest: number? = nil
	for _, Wake in State.Tx.TouchAt do
		Soonest = Composed.EarliestAfter(Soonest, Wake.At, Clock)
	end
	return Soonest
end

local function OnTouchRead(State: State, Key: StoreKey, Fetched: ReadOutcome, Clock: number)
	if Fetched.Kind == "Failed" then
		return
	end
	local Server = State.Server
	Numbers.LearnStored(Server, Key, Cache.StoreOf(Server, Key).Setup, Fetched, Clock)
end

local function HearEnds(
	State: State,
	Key: StoreKey,
	Carried: { End },
	Result: Outcome,
	Commands: { Command }
): { Finished }
	if Result.Kind == "Err" then
		return {}
	end
	local Server = State.Server
	local Note = Result.Note
	local Finished = Rides.Heard(Server, Key, Carried, Note)
	Numbers.LearnFromNote(Server, Numbers.EntryFor(Server, Key), Key, Cache.StoreOf(Server, Key).Setup, Note)
	Sending.WarnFromNote(Key, Note, Commands)
	Server.WorkSeen[Names.KeyText(Key)] = nil
	return Finished
end

local function AfterWork(State: State, Key: StoreKey, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Touching: TouchWaiter = { Kind = "Touch", Key = Key }
	if not IsWorking(State, Touching) then
		LandTouch(State, Key, Clock, Commands)
	end
end

return {
	Level = Level,
	NoteSeen = NoteSeen,
	ItemsDue = ItemsDue,
	IsWorking = IsWorking,
	AfterEvent = AfterEvent,
	ActForSession = ActForSession,
	IsDueForSession = IsDueForSession,
	TouchItem = TouchItem,
	NextWake = NextWake,
	OnTouchRead = OnTouchRead,
	SendEnds = SendEnds,
	HearEnds = HearEnds,
	AfterWork = AfterWork,
}
