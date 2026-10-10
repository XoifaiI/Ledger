--!strict
--!optimize 2

--[=[
	Help: the work any server does on another use's marks for a writer, a read, a call or a touch that met them
	(transaction sheet 16, 18.3, record 8.2, 8.3). EndWork is TX-END: the waiter goes on after its retry gap and
	the help. A writer's priority is its oldest unheard op's. Past the close deadline it sends nothing.

	Return type: A plain table with IsYounger, NeededBlockers, StartHelp, OnDeciderRead, OnHelpFence, HelpWaitDue,
	HelpDone, OnVerified and EndWork, and the Use type.
	Example usage:
		Help.EndWork(State, { Kind = "Writer", Key = Key }, Key, Report, Clock, Commands)
--]=]

local Book = require("../../Stored/Book")
local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local Decision = require("../Legs/Decision")
local Ends = require("../Legs/Ends")
local Entries = require("../../Stored/Entries")
local Events = require("../../Events")
local JudgingShapes = require("../../Judging/Shapes")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Rides = require("../Rides")
local Shapes = require("../../Shapes")
local Timed = require("../../Stored/Items/Timed")
local TxState = require("../State")
local Verify = require("./Verify")
local Work = require("../../Stored/Items/Work")
local Writers = require("../../Writing/Writer")

type Command = Events.Command
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type Name = Names.Name
type StoreKey = Names.StoreKey
type EndWorkReport = JudgingShapes.EndWorkReport
type Limits = Shapes.Limits
type ServerState = Shapes.ServerState
type Shortage = JudgingShapes.Shortage
type Op = Shapes.Op
type WriterState = Shapes.WriterState
type Mark = Work.Mark
type MarkOpening = Work.MarkOpening
type PinnedRecord = Work.PinnedRecord
type StandingMark = Work.StandingMark
type State = Composed.State
type Help = TxState.Help
type Purpose = TxState.Purpose
type Waiter = TxState.Waiter

export type Use = { read Stamp: number, read Name: Name }

local WorkItemRoom = Book.Rooms.Work

local function IsYounger(Left: Use, Right: Use): boolean
	return Timed.StampThenName(Right.Stamp, Right.Name, Left.Stamp, Left.Name)
end

local function NeededBlockers(
	Listed: { Mark },
	Short: Shortage,
	Epoch: number,
	ServerNumber: number,
	Limits: Limits
): { Mark }
	local Needed: { Mark } = {}
	local Marked = 0
	local Bytes = 0
	for _, Item in Verify.FromOffset(Listed, ServerNumber) do
		if Marked >= Short.Items and Bytes >= Short.Bytes then
			break
		end
		table.insert(Needed, Item)
		if Item.Kind ~= "Pinned" then
			Marked += 1
		end
		Bytes += Limits.ItemSize(WorkItemRoom, Item, Epoch, Limits.WindowUnit)
	end
	return Needed
end

local function EpochOf(Listed: { Mark }, Clock: number): number
	local Epoch = Clock
	for _, Item in Listed do
		Epoch = math.min(Epoch, Item.Opening.Stamp)
	end
	return Epoch
end

local function WorkedItems(Server: ServerState, Key: StoreKey, Report: EndWorkReport, Clock: number): { Mark }
	local ServerNumber = Numbers.ServerNumberOf(Server)
	local Short = if Report.Kind == "NoRoom" then Report.Short else nil
	if Short == nil then
		return Verify.FromOffset(Report.Marks, ServerNumber)
	end
	local Limits = Cache.StoreOf(Server, Key).Setup.Limits
	return NeededBlockers(Report.Marks, Short, EpochOf(Report.Marks, Clock), ServerNumber, Limits)
end

local function DeciderKeyOf(Help: Help, Blocker: StandingMark): StoreKey
	return Names.KeyOfReference(Help.Key, Blocker.Decider)
end

local function AskDecider(State: State, Help: Help, Blocker: number, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Decider = DeciderKeyOf(Help, Help.Blockers[Blocker])
	local Purpose: Purpose = { Kind = "HelpRead", HelpId = Help.Id, Blocker = Blocker, Key = Decider }
	local Get: Command =
		{ Kind = "Get", RequestId = TxState.NewRequest(State.Server, State.Tx, Purpose), Target = Decider }
	table.insert(Commands, Get)
end

local function RideDecision(Help: Help, Blocker: StandingMark, Says: Decision.DeciderSays)
	local End = Decision.ResolveFor(Blocker, Says)
	if End ~= nil then
		table.insert(Help.EndsToRide, End)
	end
end

local function IsYoungerThanOp(Opening: MarkOpening, Op: Op, Stamp: number): boolean
	local Form = Op.Form
	if Form.Kind == "Timed" or Form.Kind == "Untimed" then
		return IsYounger(Opening, { Stamp = Stamp, Name = Entries.PlainName(Form.Name) })
	end
	return Opening.Stamp > Stamp
end

local function IsYoungerThanWriter(Writer: WriterState, Opening: MarkOpening): boolean
	for _, Op in Writer.Queue do
		local Stamp = Op.Stamp
		if not Op.IsHeard and Stamp ~= nil and IsYoungerThanOp(Opening, Op, Stamp) then
			return true
		end
	end
	return false
end

local function MayFenceAtOnce(State: State, For: Waiter, Opening: MarkOpening): boolean
	if For.Kind == "Writer" then
		local Writer = Writers.WriterFor(State.Server, For.Key)
		return Writer ~= nil and IsYoungerThanWriter(Writer, Opening)
	end
	if For.Kind == "Call" then
		local Call = State.Tx.Calls[For.CallId]
		if Call == nil then
			return false
		end
		return IsYounger(Opening, { Stamp = Call.Stamp, Name = Entries.PlainName(Call.Name) })
	end
	return For.Kind == "Cut"
end

local function SendFence(State: State, Help: Help, Blocker: number, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Fence = Decision.FenceFor(Help.Blockers[Blocker])
	local Decider = DeciderKeyOf(Help, Help.Blockers[Blocker])
	local Purpose: Purpose = { Kind = "HelpFence", HelpId = Help.Id, Blocker = Blocker, Key = Decider }
	local Update: Command = {
		Kind = "Update",
		RequestId = TxState.NewRequest(State.Server, State.Tx, Purpose),
		Target = Decider,
		Request = Ends.EndsRequest({ Fence }),
	}
	table.insert(Commands, Update)
end

local function EndWait(State: State, Help: Help, Clock: number, Commands: { Command })
	local For = Help.For
	if For.Kind == "Writer" then
		local Writer = Writers.WriterFor(State.Server, For.Key)
		if Writer ~= nil and Writer.HelpId == Help.Id then
			Writer.HelpId = nil
			Composed.NoteSendable(State, For.Key)
		end
	elseif For.Kind == "Read" then
		local Out = State.Reads[For.ReadRequestId]
		if Out ~= nil and Out.HelpId == Help.Id then
			Out.HelpId = nil
			local Wake: Command = { Kind = "Wake", At = Clock }
			table.insert(Commands, Wake)
		end
	end
end

local function HoldRides(Server: ServerState, Help: Help, Clock: number)
	local For = Help.For
	for _, End in Help.EndsToRide do
		if For.Kind == "Call" then
			Rides.AddForCall(Server, Help.Key, End, For.CallId)
		else
			Rides.Add(Server, Help.Key, End, Clock)
		end
	end
end

local function HelpDone(State: State, Help: Help, Clock: number, Commands: { Command }): Waiter
	HoldRides(State.Server, Help, Clock)
	State.Tx.Helps[Help.Id] = nil
	EndWait(State, Help, Clock, Commands)
	return Help.For
end

local function BlockerDone(State: State, Help: Help, Clock: number, Commands: { Command }): Waiter?
	Help.Left -= 1
	if Help.Left > 0 then
		return nil
	end
	return HelpDone(State, Help, Clock, Commands)
end

local function StartHelp(
	State: State,
	For: Waiter,
	Key: StoreKey,
	Report: EndWorkReport,
	Clock: number,
	Commands: { Command }
): number
	local Server = State.Server
	local Help: Help = {
		Id = TxState.NextId(State.Tx),
		For = For,
		Key = Key,
		Blockers = {},
		AskedAt = {},
		EndsToRide = {},
		Waiting = {},
		Left = 0,
	}
	State.Tx.Helps[Help.Id] = Help
	local Worked = WorkedItems(Server, Key, Report, Clock)
	local IsWorked: { [Mark]: boolean } = {}
	for _, Item in Worked do
		IsWorked[Item] = true
		if Item.Kind ~= "Pinned" and Cache.IsReachable(Server, DeciderKeyOf(Help, Item)) then
			table.insert(Help.Blockers, Item)
			local Blocker = #Help.Blockers
			Help.AskedAt[Blocker] = Clock
			Help.Left += 1
			AskDecider(State, Help, Blocker, Clock, Commands)
		end
	end
	local Records: { PinnedRecord } = {}
	for _, Item in Report.Marks do
		if Item.Kind == "Pinned" and IsWorked[Item] then
			table.insert(Records, Item)
		end
	end
	if #Records > 0 then
		local Verifying: Waiter = { Kind = "Help", HelpId = Help.Id }
		if Verify.Start(State, Verifying, Key, Records, Clock, Commands) ~= nil then
			Help.Left += 1
		end
	end
	if Help.Left == 0 then
		HelpDone(State, Help, Clock, Commands)
	end
	return Help.Id
end

local function OnDeciderRead(
	State: State,
	Help: Help,
	Blocker: number,
	Fetched: ReadOutcome,
	Clock: number,
	Commands: { Command }
): Waiter?
	if Fetched.Kind == "Failed" then
		return BlockerDone(State, Help, Clock, Commands)
	end
	local Server = State.Server
	local Mark = Help.Blockers[Blocker]
	local Opening = Mark.Opening
	local Decider = DeciderKeyOf(Help, Mark)
	local Limits = Cache.StoreOf(Server, Help.Key).Setup.Limits
	local Read = Numbers.LearnStored(Server, Decider, Cache.StoreOf(Server, Decider).Setup, Fetched, Clock)
	if Read.Kind == "Unreadable" then
		return BlockerDone(State, Help, Clock, Commands)
	end
	local Says = Decision.DecisionShown(if Read.Kind == "Kept" then Read.Kept else nil, Opening)
	if Says.Kind == "Undecided" then
		if Clock - Opening.Stamp >= Limits.SettleAge or MayFenceAtOnce(State, Help.For, Opening) then
			SendFence(State, Help, Blocker, Clock, Commands)
		else
			Help.Waiting[Blocker] = Opening.Stamp + Limits.SettleAge
		end
		return nil
	end
	if Decision.IsOrphanEvidence(Says, Help.AskedAt[Blocker], Opening.Stamp, Limits.OrphanAge) then
		table.insert(Help.EndsToRide, Decision.OrphanEnd(Mark))
	end
	RideDecision(Help, Mark, Says)
	return BlockerDone(State, Help, Clock, Commands)
end

local function OnHelpFence(
	State: State,
	Help: Help,
	Blocker: number,
	Outcome: Outcome,
	Clock: number,
	Commands: { Command }
): Waiter?
	if Outcome.Kind ~= "Err" then
		Numbers.SeeLeftOver(State.Server, DeciderKeyOf(Help, Help.Blockers[Blocker]), Outcome.Note)
	end
	RideDecision(Help, Help.Blockers[Blocker], Decision.FenceSays(Ends.LoneEndReport(Outcome)))
	return BlockerDone(State, Help, Clock, Commands)
end

local function IsWaitDue(Help: Help, Clock: number): boolean
	for _, DueAt in Help.Waiting do
		if Clock >= DueAt then
			return true
		end
	end
	return false
end

local function HelpWaitDue(State: State, Help: Help, Clock: number, Commands: { Command })
	for Blocker = 1, #Help.Blockers do
		local DueAt = Help.Waiting[Blocker]
		if DueAt ~= nil and Clock >= DueAt then
			Help.Waiting[Blocker] = nil
			SendFence(State, Help, Blocker, Clock, Commands)
		end
	end
end

local function OnVerified(State: State, HelpId: number, Clock: number, Commands: { Command }): Waiter?
	local Help = State.Tx.Helps[HelpId]
	if Help == nil then
		return nil
	end
	return BlockerDone(State, Help, Clock, Commands)
end

local function WaitOnHelp(State: State, For: Waiter, HelpId: number)
	if For.Kind == "Writer" then
		local Writer = Writers.WriterFor(State.Server, For.Key)
		if Writer ~= nil then
			Writer.HelpId = HelpId
		end
	elseif For.Kind == "Read" then
		local Out = State.Reads[For.ReadRequestId]
		if Out ~= nil then
			Out.HelpId = HelpId
		end
	end
end

local function EndWork(
	State: State,
	For: Waiter,
	Key: StoreKey,
	Report: EndWorkReport,
	Clock: number,
	Commands: { Command }
)
	local HelpId = StartHelp(State, For, Key, Report, Clock, Commands)
	if State.Tx.Helps[HelpId] ~= nil then
		WaitOnHelp(State, For, HelpId)
	end
end

return {
	IsYounger = IsYounger,
	NeededBlockers = NeededBlockers,
	StartHelp = StartHelp,
	OnDeciderRead = OnDeciderRead,
	OnHelpFence = OnHelpFence,
	IsWaitDue = IsWaitDue,
	HelpWaitDue = HelpWaitDue,
	HelpDone = HelpDone,
	OnVerified = OnVerified,
	EndWork = EndWork,
}
