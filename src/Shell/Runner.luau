--!strict
--!optimize 2

--[=[
	Runner: the server's loop, wakes, stores and close. Events step at once, even inside commands; an unhandled command
	faults. A step's answers leave Pending before its other commands, settling after them and its outcomes, the close's
	last. Wakes fire at whole-second stamps. BeforeClose functions get BeforeCloseSeconds of the close's deadline, which
	no fault passes. A store-less Id brings default Limits.

	Return type: A plain table with Start, AddStore, AddBeforeClose, IsOpened, OpenedSetup, Call, CallWithOutcome,
	WouldWait, CallNow, CallNowForId, CloseAll, IsClosing and IsStepping.
	Example usage:
		Runner.Start()
		Runner.AddStore(Setup, false)
		local Answer = Runner.CallNow(Call)
--]=]

local Calls = require("./Calls")
local Composed = require("../Composed")
local CoreCalls = require("../Calls")
local CoreClosing = require("../Sessions/Closing")
local Events = require("../Events")
local Future = require("../Util/Future")
local Memory = require("./Memory")
local Names = require("../Encoding/Names")
local Platform = require("./Platform")
local Replies = require("../Replies")
local Requests = require("./Requests")
local Shapes = require("../Shapes")
local ShellLimits = require("./Limits")
local Step = require("../Step")
local Stepping = require("./Stepping")
local Streams = require("./Streams")
local Threads = require("../Util/Threads")

type Answer = Events.Answer
type AnswerCommand = Events.AnswerCommand
type Call = Events.Call
type Command = Events.Command
type Event = Events.Event
type Happening = Events.Happening
type ReadyCommand = Events.ReadyCommand
type UpdateCommand = Events.UpdateCommand
type WakeCommand = Events.WakeCommand
type WarnCommand = Events.WarnCommand
type Future<T...> = Future.Future<T...>
type Outcome = Calls.Outcome
type OutcomeEmission = Replies.OutcomeEmission
type Setup = Shapes.Setup
type State = Composed.State
type Store = Requests.Store
type StoreKey = Names.StoreKey

type Feed = (Happening: Happening) -> ()

type Handler = (Command: Command, Feed: Feed) -> ()

type Timer = { read At: number, read Thread: thread }

local CloseMethod: "CloseAll" = "CloseAll"
local BeforeCloseSeconds = 5

local NotStarted = "Runner: Start has not run, so the server has no state to step."
local StartedTwice = "Runner: Start ran twice. The server has one loop, and it starts once."

local function NoHandler(Kind: string): string
	return `Runner: the core emitted a command of kind {Kind}, which no handler runs.`
end

local function AlreadyOpened(Name: string): string
	return `Runner: the store {Name} was opened on this server before. A store name is kept for the server's life.`
end

local function NoStore(Name: string): string
	return `Runner: a request targets the store {Name}, which this server never opened.`
end

local function NoSetup(Name: string): string
	return `Runner: the store {Name} was never opened on this server, so it has no Setup. Ask IsOpened first.`
end

local ServerClosing = "Ledger.BeforeClose: the server is closing, so a function registered now would never run. "
	.. "Register it before the close starts"

local function BeforeCloseErrored(Trace: string): string
	return `Ledger: a BeforeClose function errored, and the close goes on without it: {Trace}`
end

local Current: State? = nil
local Stores: { [string]: Store } = {}
local Waking: Timer? = nil
local Closing: Future<()>? = nil
local CloseCallId: number? = nil
local BeforeCloseFunctions: { () -> () } = {}

local Feed: Feed

local function StateOf(): State
	if Current == nil then
		error(NotStarted, 0)
	end
	return Current
end

local function StoreOf(Target: StoreKey): Store
	local Found = Stores[Target.Store]
	if Found == nil then
		error(NoStore(Target.Store), 0)
	end
	return Found
end

local function OnUpdate(Command: UpdateCommand, Feed: Feed)
	Requests.OnUpdate(Command, StoreOf(Command.Target), Feed)
end

local function Arm(At: number, Feed: Feed)
	local DueSecond = math.ceil(At)
	local Thread = Threads.Delay(math.max(Platform.SecondsUntil(DueSecond), 0), function()
		Waking = nil
		if Platform.Now() < At then
			return Arm(At, Feed)
		end
		Feed({ Kind = "Clock" })
	end)
	Waking = { At = At, Thread = Thread }
end

local function OnWake(Command: WakeCommand, Feed: Feed)
	local Kept = Waking
	if Kept ~= nil then
		if Kept.At <= Command.At then
			return
		end
		Threads.Cancel(Kept.Thread)
	end
	Arm(Command.At, Feed)
end

local function OnReady(Command: ReadyCommand, Feed: Feed)
	Feed({ Kind = "Send", Key = Command.Key })
end

local function OnWarn(Command: WarnCommand)
	local Key = Command.Key
	if Key == nil then
		warn(Command.Text)
		return
	end
	warn(`Ledger: {Key.Store}/{Key.Scope}/{Key.Key}: {Command.Text}`)
end

local Handlers = {
	Update = OnUpdate,
	Count = Requests.OnCount,
	Get = Requests.OnGet,
	Remove = Requests.OnRemove,
	MemoryGet = Memory.OnGet,
	MemorySet = Memory.OnSet,
	MemoryUpdate = Memory.OnUpdate,
	MemoryRemove = Memory.OnRemove,
	Decode = Memory.OnDecode,
	Emit = Streams.OnEmit,
	Wake = OnWake,
	Ready = OnReady,
	Warn = OnWarn,
}

local function AnswersOf(Commands: { Command }): { AnswerCommand }
	local Answers: { AnswerCommand } = {}
	local CloseAnswers: { AnswerCommand } = {}
	for _, Command in Commands do
		if Command.Kind == "Answer" then
			table.insert(if Command.CallId == CloseCallId then CloseAnswers else Answers, Command)
		end
	end
	table.move(CloseAnswers, 1, #CloseAnswers, #Answers + 1, Answers)
	return Answers
end

local function IsOutcome(Command: Command): boolean
	return Command.Kind == "Emit" and Command.Stream == Replies.OutcomeStream
end

local function OutcomesOf(Commands: { Command }): { OutcomeEmission }
	local Settled: { OutcomeEmission } = {}
	for _, Command in Commands do
		if Command.Kind == "Emit" and IsOutcome(Command) then
			table.insert(Settled, Command.Value :: OutcomeEmission)
		end
	end
	return Settled
end

local function Run(Commands: { Command })
	local Waiters = Calls.Claim(AnswersOf(Commands))
	for _, Command in Commands do
		if Command.Kind == "Answer" or IsOutcome(Command) then
			continue
		end
		local Handler = (Handlers :: { [string]: Handler })[Command.Kind]
		if Handler == nil then
			error(NoHandler(Command.Kind), 0)
		end
		Handler(Command, Feed)
	end
	Calls.SettleOutcomes(OutcomesOf(Commands))
	Calls.Resume(Waiters)
end

local function FeedAt(Clock: number, Happening: Happening)
	local Event: Event = { Clock = Clock, Happening = Happening }
	local _, Commands = Stepping.Run(Step.Step, StateOf(), Event)
	Run(Commands)
end

function Feed(Happening: Happening)
	FeedAt(Platform.Now(), Happening)
end

local function Call(Made: Call): Future<Answer>
	local Job = Calls.Open(Made.CallId, Made.Method)
	Feed(Made)
	return Job
end

local function CallWithOutcome(Made: Call): Future<Answer, Outcome?>
	local Job = Calls.OpenWithOutcome(Made.CallId, Made.Method)
	Feed(Made)
	return Job
end

local function WouldWait(Made: Call): boolean
	return CoreCalls.WouldWait(StateOf(), Made, Platform.Now())
end

local function CallNow(Made: Call): Answer
	Calls.Expect(Made.CallId)
	Feed(Made)
	local Given = Calls.Take(Made.CallId)
	if Given ~= nil then
		return Given
	end
	return Calls.Open(Made.CallId, Made.Method):Wait()
end

local function CallNowForId(Made: Call): Answer
	if next(Stores) == nil then
		Composed.RecordServerLimits(StateOf(), ShellLimits.BuildDefault(Platform.IsStudio()))
	end
	return CallNow(Made)
end

local function SecondsLeft(Deadline: number?): number
	if Deadline == nil then
		return 0
	end
	return math.max(Platform.SecondsUntil(Deadline), 0)
end

local function EndByDeadline(Answered: Future<Answer>, Deadline: number?, EndClose: () -> ())
	Answered:Wait(SecondsLeft(Deadline))
	if not Answered:Happened() then
		local Tick: Happening = { Kind = "Clock" }
		Threads.Spawn(Feed, Tick)
	end
	Calls.CloseAll()
	EndClose()
end

local function Called(Body: () -> ()): string?
	Body()
	return nil
end

local function TraceOf(Problem: unknown): string
	return debug.traceback(tostring(Problem))
end

local function WaitForBeforeClose()
	local Running = #BeforeCloseFunctions
	local AllReturned: Future<()>, EndAll: () -> () = Future.Pending()
	local function RunOne(Body: () -> ())
		local _, Trace = xpcall(Called, TraceOf, Body)
		if Trace ~= nil then
			warn(BeforeCloseErrored(Trace))
		end
		Running -= 1
		if Running == 0 then
			EndAll()
		end
	end
	for _, Body in BeforeCloseFunctions do
		Threads.Spawn(RunOne, Body)
	end
	AllReturned:Wait(BeforeCloseSeconds)
end

local function Started(): Future<()>
	local Kept = Closing
	if Kept ~= nil then
		return Kept
	end
	local Ended: Future<()>, EndClose: () -> () = Future.Pending()
	Closing = Ended
	local Began = Platform.Now()
	local Deadline = CoreClosing.ShutdownDeadline(StateOf().Server, Began)
	local Clock = Began
	if #BeforeCloseFunctions > 0 then
		WaitForBeforeClose()
		Clock = Platform.Now()
	end
	local CloseCall: Call = { Kind = "Call", Method = CloseMethod, CallId = Calls.NewCallId(), BeganAt = Began }
	CloseCallId = CloseCall.CallId
	local Answered = Calls.Open(CloseCall.CallId, CloseCall.Method)
	Threads.Spawn(EndByDeadline, Answered, Deadline, EndClose)
	FeedAt(Clock, CloseCall)
	return Ended
end

local function CloseAll()
	Started():Wait()
end

local function IsClosing(): boolean
	return Closing ~= nil
end

local function Start()
	if Current ~= nil then
		error(StartedTwice, 0)
	end
	Current = Composed.NewState(Composed.NewServer(Platform.JobId(), Platform.Encoding))
	game:BindToClose(CloseAll)
end

local function AddBeforeClose(Body: () -> ())
	if Closing ~= nil then
		error(ServerClosing, 0)
	end
	table.insert(BeforeCloseFunctions, Body)
end

local function IsOpened(Name: string): boolean
	return Stores[Name] ~= nil
end

local function OpenedSetup(Name: string): Setup
	local Found = Stores[Name]
	if Found == nil then
		error(NoSetup(Name), 0)
	end
	return Found.Setup
end

local function AddStore(Setup: Setup, IsPlayerStore: boolean)
	local Running = StateOf()
	if IsOpened(Setup.Store) then
		error(AlreadyOpened(Setup.Store), 0)
	end
	Composed.OpenStore(Running, Setup)
	Stores[Setup.Store] = { Setup = Setup, IsPlayerStore = IsPlayerStore }
	Feed({ Kind = "Clock" })
end

return {
	Start = Start,
	AddStore = AddStore,
	AddBeforeClose = AddBeforeClose,
	IsOpened = IsOpened,
	OpenedSetup = OpenedSetup,
	Call = Call,
	CallWithOutcome = CallWithOutcome,
	WouldWait = WouldWait,
	CallNow = CallNow,
	CallNowForId = CallNowForId,
	CloseAll = CloseAll,
	IsClosing = IsClosing,
	IsStepping = Stepping.IsStepping,
}
