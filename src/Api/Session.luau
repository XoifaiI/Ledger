--!strict
--!optimize 2

--[=[
	Session: a player's key from Load to its Release's answer (record 6), the object the game holds. A released object
	throws, never reaching the core. An Apply inside a listener delivers its view nested, so Get is current. An op's
	fate is unknown when it came back Unknown or has not come. Refresh reads at most once at a time.

	Return type: A plain table with New, Phase, PhaseOf, Opened, NotOpened, EndUnanswered, MarkLeaving, End,
	WaitForLoad, LoadFailureOf, WaitForEnd and UnknownFateCount, and the Session type.
	Example usage:
		local Ok, Handle, Info = Session:Apply({ Kind = "AddGold", Amount = 5 })
		local Took, Reason, Queued = Session:DidApply(Handle)
--]=]

local Answers = require("./Answers")
local Args = require("./Validate/Args")
local Calls = require("../Shell/Calls")
local Events = require("../Events")
local Future = require("../Util/Future")
local GameValues = require("./GameValues")
local Names = require("../Encoding/Names")
local Observer = require("../Util/Observer")
local ProbeAdvice = require("./ProbeAdvice")
local Reasons = require("../Constants/Reasons")
local Runner = require("../Shell/Runner")
local Shapes = require("../Shapes")
local ShellSetup = require("../Shell/Setup")
local Streams = require("../Shell/Streams")
local Types = require("../Types")
local WritingAnswers = require("../Writing/Answers")

type Answer = Events.Answer
type Applied = Types.Applied
type AskedName = Shapes.AskedName
type Call = Events.Call
type CommitOptions = Types.CommitOptions
type Connection = Observer.Connection
type DidApplyInfo = Types.DidApplyInfo
type DidApplyOptions = Types.DidApplyOptions
type Fate = Types.Fate
type FateEmission = WritingAnswers.FateEmission
type Future<T...> = Future.Future<T...>
type Info = Types.Info
type Name = Types.Name
type Observer<T> = Observer.Observer<T>
type Op = Types.Op
type Reason = Types.Reason
type Settings = ShellSetup.Settings
type StoreKey = Names.StoreKey
type Subject<T> = Observer.Subject<T>

type Fated = { read Emission: FateEmission, read Handle: Applied }

local Phase = {
	Loading = "Loading" :: "Loading",
	Leaving = "Leaving" :: "Leaving",
	Loaded = "Loaded" :: "Loaded",
	Releasing = "Releasing" :: "Releasing",
	Released = "Released" :: "Released",
}

export type Phase = keyof<typeof(Phase)>

type SessionData = {
	read Settings: Settings,
	read Player: Player,
	read Key: StoreKey,
	Phase: Phase,
	LoadFailure: Reason?,
	read LoadEnded: Future<boolean>,
	read EndLoad: (IsLoaded: boolean) -> (),
	read Ended: Future<()>,
	read EndSession: () -> (),
	read Handles: { [number]: Applied },
	read Unfated: { [unknown]: true },
	read FateSubject: Subject<Fated>,
	UnknownFates: number,
	FateWatch: Connection?,
	CoreView: unknown,
	GameView: unknown,
}

local NoView = "Session: a loaded session's key has no view kept. The core emits a view whenever a session opens"

local function NotCurrent(Where: string): string
	return `{Where}: the session must be its key's current one, got a released session. Get the player's session again`
end

local function DidApplyCallOf(Key: StoreKey, Asked: AskedName, IsProbe: boolean): Call
	if IsProbe then
		return {
			Kind = "Call",
			Method = "DidApplyWithProbe" :: "DidApplyWithProbe",
			CallId = Calls.NewCallId(),
			Key = Key,
			Name = Asked,
		}
	end
	return { Kind = "Call", Method = "DidApply" :: "DidApply", CallId = Calls.NewCallId(), Key = Key, Name = Asked }
end

local function DidApplyAnswerOf(Made: Call, Asked: AskedName, Where: string): Answer
	if Asked.Kind == "Minted" or Asked.Kind == "Queued" then
		return Runner.CallNow(Made)
	end
	Args.OutsideListener(Where)
	return Runner.Call(Made):Wait()
end

local Session = {}
Session.__index = Session

export type Session = setmetatable<SessionData, typeof(Session)>

local function Current(Object: Session, Where: string)
	if Object.Phase ~= Phase.Loaded then
		error(NotCurrent(Where), 0)
	end
end

local function GameViewOf(Object: Session, View: unknown): unknown
	if View ~= Object.CoreView then
		Object.CoreView = View
		Object.GameView = GameValues.CopyForGame(View)
	end
	return Object.GameView
end

local function NoteFate(Object: Session, Emission: FateEmission)
	local Handle = Object.Handles[Emission.CallId]
	if Handle == nil then
		return
	end
	Object.Handles[Emission.CallId] = nil
	Object.Unfated[Handle] = nil
	if Emission.Fate.Kind == "Unknown" then
		Object.UnknownFates += 1
	end
	Object.FateSubject:Push({ Emission = Emission, Handle = Handle })
end

local function New(Settings: Settings, Player: Player, Key: StoreKey): Session
	local LoadEnded: Future<boolean>, EndLoad: (boolean) -> () = Future.Pending()
	local Ended: Future<()>, EndSession: () -> () = Future.Pending()
	local FateSubject = Observer.New() :: Subject<Fated>
	local Data: SessionData = {
		Settings = Settings,
		Player = Player,
		Key = Key,
		Phase = Phase.Loading,
		LoadEnded = LoadEnded,
		EndLoad = EndLoad,
		Ended = Ended,
		EndSession = EndSession,
		Handles = {},
		Unfated = {},
		FateSubject = FateSubject,
		UnknownFates = 0,
	}
	return setmetatable(Data, Session)
end

local function PhaseOf(Object: Session): Phase
	return Object.Phase
end

local function Opened(Object: Session)
	Object.Phase = Phase.Loaded
	Object.FateWatch = Streams.Fates(Object.Key):Subscribe(function(Emission: FateEmission)
		NoteFate(Object, Emission)
	end)
	Object.EndLoad(true)
end

local function NotOpened(Object: Session, Why: Reason?)
	Object.LoadFailure = Why
	Object.Phase = Phase.Released
	Object.EndLoad(false)
	Object.EndSession()
end

local function EndUnanswered(Object: Session)
	if Object.LoadEnded:Happened() then
		return
	end
	NotOpened(Object, Reasons.Unresolved)
end

local function MarkLeaving(Object: Session)
	if Object.Phase == Phase.Loading then
		Object.Phase = Phase.Leaving
	end
end

local function End(Object: Session): Answer
	local WasLoaded = Object.Phase == Phase.Loaded
	Object.Phase = Phase.Releasing
	local Made: Call = { Kind = "Call", Method = "Release" :: "Release", CallId = Calls.NewCallId(), Key = Object.Key }
	local Given = Runner.Call(Made):Wait()
	local Watch = Object.FateWatch
	if Watch ~= nil then
		Watch:Disconnect()
	end
	Streams.Forget(Object.Key)
	Object.FateSubject:Destroy()
	Object.Phase = Phase.Released
	if not WasLoaded then
		Object.EndLoad(false)
	end
	Object.EndSession()
	return Given
end

local function WaitForLoad(Object: Session): boolean
	Object.LoadEnded:Wait()
	return Object.Phase == Phase.Loaded
end

local function LoadFailureOf(Object: Session): Reason?
	return Object.LoadFailure
end

local function WaitForEnd(Object: Session)
	Object.Ended:Wait()
end

local function UnknownFateCount(Object: Session): number
	local Count = Object.UnknownFates
	for _ in Object.Unfated do
		Count += 1
	end
	return Count
end

function Session.Get(self: Session): unknown
	local Where = "Session:Get"
	Args.OutsideStep(Where)
	Current(self, Where)
	local View = Streams.ViewOf(self.Key)
	if View == nil then
		error(NoView, 0)
	end
	return GameViewOf(self, View)
end

function Session.Observe(self: Session): Observer<unknown>
	local Where = "Session:Observe"
	Args.OutsideStep(Where)
	Current(self, Where)
	return Streams.Views(self.Key):Map(function(View: unknown): unknown
		return GameViewOf(self, View)
	end)
end

function Session.ObserveFates(self: Session): Observer<Fate>
	local Where = "Session:ObserveFates"
	Args.OutsideStep(Where)
	Current(self, Where)
	return self.FateSubject:Map(function(Fated: Fated): Fate
		return Answers.FateOf(Fated.Emission, Fated.Handle)
	end)
end

function Session.Apply(self: Session, Op: Op): (boolean, Applied | Reason, Info?)
	local Where = "Session:Apply"
	Args.OutsideStep(Where)
	Current(self, Where)
	local OpKind, Terms = Args.Op(self.Settings, Op, Where)
	local Made: Call = {
		Kind = "Call",
		Method = "Apply" :: "Apply",
		CallId = Calls.NewCallId(),
		Key = self.Key,
		OpKind = OpKind,
		Terms = Terms,
	}
	if Runner.WouldWait(Made) then
		Args.OutsideListener(Where)
	end
	local Ok, Handed, Info = Answers.ApplyAnswer(Runner.CallNow(Made), Made.CallId, self.Key)
	if type(Handed) == "table" then
		self.Handles[Made.CallId] = Handed
		self.Unfated[Handed] = true
	end
	return Ok, Handed, Info
end

function Session.Commit(self: Session, Op: Op, Options: CommitOptions?): (boolean, unknown, Info?)
	local Where = "Session:Commit"
	Args.OutsideStep(Where)
	Current(self, Where)
	local Name = Args.CommitName(Options, Where)
	local OpKind, Terms = Args.Op(self.Settings, Op, Where)
	Args.UntimedWindow(self.Settings, OpKind, Name, Where)
	Args.OutsideListener(Where)
	local Made: Call = {
		Kind = "Call",
		Method = "Commit" :: "Commit",
		CallId = Calls.NewCallId(),
		Key = self.Key,
		OpKind = OpKind,
		Terms = Terms,
		Name = Name,
	}
	local Answered, Outcome = Runner.CallWithOutcome(Made):Wait()
	local Ok, Result, Info = Answers.CommitAnswer(Answered)
	return Ok, Result, Answers.WithOutcome(Info, Outcome)
end

function Session.DidApply(
	self: Session,
	Name: Applied | Name,
	Options: DidApplyOptions?
): (unknown, Reason?, DidApplyInfo?)
	local Where = "Session:DidApply"
	Args.OutsideStep(Where)
	Current(self, Where)
	local Asked, IsProbe = Args.ProbeName(Name, Options, Where)
	Args.HandleOfKey(self.Key, Name, Where)
	if self.Unfated[Name] then
		return Answers.QueuedAnswer()
	end
	local Made = DidApplyCallOf(self.Key, Asked, IsProbe)
	local Answered = DidApplyAnswerOf(Made, Asked, Where)
	ProbeAdvice.Heard(self.Settings.Name, Asked, IsProbe, Answered)
	return Answers.DidApplyAnswer(Answered)
end

function Session.Flush(self: Session): (boolean, Reason?, Info?)
	local Where = "Session:Flush"
	Args.OutsideStep(Where)
	Current(self, Where)
	Args.OutsideListener(Where)
	local Made: Call = { Kind = "Call", Method = "Flush" :: "Flush", CallId = Calls.NewCallId(), Key = self.Key }
	return Answers.Plain(Runner.Call(Made):Wait())
end

function Session.Refresh(self: Session): (boolean, Reason?)
	local Where = "Session:Refresh"
	Args.OutsideStep(Where)
	Current(self, Where)
	Args.OutsideListener(Where)
	local Made: Call = { Kind = "Call", Method = "Refresh" :: "Refresh", CallId = Calls.NewCallId(), Key = self.Key }
	local Ok, Why = Answers.Plain(Runner.Call(Made):Wait())
	return Ok, Why
end

function Session.Release(self: Session): (boolean, Reason?, Info?)
	local Where = "Session:Release"
	Args.OutsideStep(Where)
	Current(self, Where)
	Args.OutsideListener(Where)
	return Answers.Plain(End(self))
end

return {
	New = New,
	Phase = Phase,
	PhaseOf = PhaseOf,
	Opened = Opened,
	NotOpened = NotOpened,
	EndUnanswered = EndUnanswered,
	MarkLeaving = MarkLeaving,
	End = End,
	WaitForLoad = WaitForLoad,
	LoadFailureOf = LoadFailureOf,
	WaitForEnd = WaitForEnd,
	UnknownFateCount = UnknownFateCount,
}
