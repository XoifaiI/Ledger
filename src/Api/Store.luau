--!strict
--!optimize 2

--[=[
	Store: Ledger.New's object, with its methods on any key and Sessions'. Each but Leg checks its arguments, and each
	but Leg, Keys, Versions and PeekVersion then sends one call and maps its answer through Answers. A MaxAge Peek
	answering Unresolved makes one plain Peek. Keys pages game keys and Versions a key's DataStore versions, for one
	caller at a time; an erased key is not listed. PeekVersion reads one version once, outside the core, and decodes it
	through OldVersion as a step. Destroy ends the sessions, then every method throws.

	Return type: The Store class.
	Example usage:
		local Vault = Store.New(Settings)
		local State, Reason = Vault:Peek("alice")
--]=]

local Answers = require("./Answers")
local Args = require("./Validate/Args")
local Calls = require("../Shell/Calls")
local Check = require("../Record/Encoding/Check")
local Events = require("../Machine/Events")
local Keys = require("./Validate/Keys")
local Names = require("../Record/Encoding/Names")
local Observer = require("../Util/Observer")
local OldVersion = require("../Record/Reading/OldVersion")
local Pager = require("./Pager")
local Platform = require("../Shell/Platform")
local ProbeAdvice = require("./ProbeAdvice")
local Quantity = require("./Quantity")
local QuantityArgs = require("./Validate/Quantity")
local Reasons = require("../Record/Constants/Reasons")
local Rules = require("./Validate/Rules")
local Runner = require("../Shell/Runner")
local Services = require("../Shell/Services")
local Session = require("./Session")
local Sessions = require("./Sessions")
local Shapes = require("../Machine/Shapes")
local ShellSetup = require("../Shell/Setup")
local Stepping = require("../Shell/Stepping")
local Stores = require("./Validate/Stores")
local Streams = require("../Shell/Streams")
local Types = require("../Types")

type Answer = Events.Answer
type AskedName = Shapes.AskedName
type Call = Events.Call
type Cut = Types.Cut
type DidApplyOptions = Types.DidApplyOptions
type EditOptions = Types.EditOptions
type Info = Types.Info
type KeyLike = Types.KeyLike
type KeyVersion = Types.KeyVersion
type LegOptions = Types.LegOptions
type Observer<T> = Observer.Observer<T>
type LossRecords = Types.LossRecords
type Name = Types.Name
type Op = Types.Op
type PeekOptions = Types.PeekOptions
type Quantity = Quantity.Quantity
type Reason = Types.Reason
type Rule = Check.Rule
type EraseOptions = Types.EraseOptions
type BumpOptions = Types.BumpOptions
type ResetOptions = Types.ResetOptions<unknown>
type Session = Session.Session
type Settings = ShellSetup.Settings
type StoreKey = Names.StoreKey
type Terms = Types.Terms

type StoreData = {
	read Settings: Settings,
	read Sessions: { [string]: Session },
	read Follows: { [Observer<unknown>]: true },
	read Stales: { [Observer<string | number>]: true },
	read Quantities: { [string]: Quantity },
}

local WeakKeys = { __mode = "k" }

local FollowWhere = "Store:Follow"
local LegWhere = "Store:Leg"

local VersionRule = Check.TextAtLeast(1)

local LegOptionRules: { [string]: Rule } = {
	MustExist = Check.AnyValue,
	Slot = Check.AnyValue,
}

local IsStaleAsked = false

local function FatesUnknown(Name: string, Count: number): string
	return `Ledger: {Name} was destroyed with {Count} ops of its released sessions whose fate is unknown. `
		.. "They may or may not have been saved."
end

local function FollowOf(Object: unknown, Key: StoreKey): Observer<Answer>
	local function Start()
		Args.OutsideStep(FollowWhere)
		if not Stores.IsLive(Object) then
			return
		end
		local Following: Call = { Kind = "Call", Method = "Follow" :: "Follow", CallId = Calls.NewCallId(), Key = Key }
		Runner.Call(Following)
	end
	local function Stop()
		Args.OutsideStep(FollowWhere)
		if not Stores.IsLive(Object) then
			return
		end
		local Unfollowing: Call =
			{ Kind = "Call", Method = "Unfollow" :: "Unfollow", CallId = Calls.NewCallId(), Key = Key }
		Runner.Call(Unfollowing)
	end
	return Streams.Follows(Key, Start, Stop)
end

local function AskStale()
	if IsStaleAsked then
		return
	end
	IsStaleAsked = true
	local Watching: Call = { Kind = "Call", Method = "Stale" :: "Stale", CallId = Calls.NewCallId() }
	Runner.Call(Watching)
end

local function PlainPeekOf(Key: StoreKey): Call
	return { Kind = "Call", Method = "Peek" :: "Peek", CallId = Calls.NewCallId(), Key = Key }
end

local function PeekCallOf(Key: StoreKey, Freshness: unknown, Where: string): Call
	if Freshness == nil then
		return PlainPeekOf(Key)
	end
	if type(Freshness) ~= "table" then
		local MaxAge = Args.MaxAge(Freshness, Where)
		return {
			Kind = "Call",
			Method = "PeekWithin" :: "PeekWithin",
			CallId = Calls.NewCallId(),
			Key = Key,
			MaxAge = MaxAge,
		}
	end
	if Args.PeekOptions(Freshness, Where) then
		return { Kind = "Call", Method = "PeekFresh" :: "PeekFresh", CallId = Calls.NewCallId(), Key = Key }
	end
	return PlainPeekOf(Key)
end

local function IsFailedWith(Answered: Answer, Reason: Reason): boolean
	return Answered.Kind == "Failed" and Answered.Reason == Reason
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

local function DidApplyOutsideListener(Asked: AskedName, Where: string)
	if Asked.Kind == "Minted" or Asked.Kind == "Queued" then
		return
	end
	Args.OutsideListener(Where)
end

local function EndEach<T>(Observers: { [Observer<T>]: true })
	local Made = next(Observers)
	while Made ~= nil do
		Observers[Made] = nil
		Made:Destroy()
		Made = next(Observers)
	end
end

local Store = {}
Store.__index = Store

export type Store = setmetatable<StoreData, typeof(Store)>

type Leg = {
	read Store: Store,
	read Key: KeyLike,
	read Op: Terms,
	read MustExist: unknown,
	read Slot: unknown,
}

function Store.New(Settings: Settings): Store
	local Follows: { [Observer<unknown>]: true } = {}
	setmetatable(Follows, WeakKeys)
	local Stales: { [Observer<string | number>]: true } = {}
	setmetatable(Stales, WeakKeys)
	local Data: StoreData = { Settings = Settings, Sessions = {}, Follows = Follows, Stales = Stales, Quantities = {} }
	local Made = setmetatable(Data, Store)
	Stores.Register(Made, Settings)
	return Made
end

function Store.Peek(self: Store, Key: KeyLike, Freshness: (number | PeekOptions)?): (unknown, Reason?, Info?)
	local Where = "Store:Peek"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	local Target = Keys.Key(self.Settings, Key, Where)
	local Made = PeekCallOf(Target, Freshness, Where)
	Args.OutsideListener(Where)
	local Answered = Runner.Call(Made):Wait()
	if Made.Method == "PeekWithin" and IsFailedWith(Answered, Reasons.Unresolved) then
		local Plain = Runner.Call(PlainPeekOf(Target)):Wait()
		if not IsFailedWith(Plain, Reasons.Closed) then
			Answered = Plain
		end
	end
	return Answers.PeekAnswer(Answered)
end

function Store.Keys(self: Store, Prefix: string?): Pager.Pager<string, string | number>
	local Where = "Store:Keys"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	local Given = Keys.Prefix(self.Settings, Prefix, Where)
	Args.OutsideListener(Where)
	return Pager.Keys(self, self.Settings, Given)
end

function Store.Versions(self: Store, Key: KeyLike): Pager.Pager<KeyVersion, KeyVersion>
	local Where = "Store:Versions"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	local Target = Keys.Key(self.Settings, Key, Where)
	Args.OutsideListener(Where)
	return Pager.Versions(self, self.Settings, Target)
end

function Store.PeekVersion(self: Store, Key: KeyLike, Version: string): (unknown, Reason?)
	local Where = "Store:PeekVersion"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self, Settings.Name)
	local Target = Keys.Key(Settings, Key, Where)
	Check.Table({ Version = Version }, { Version = VersionRule }, Where)
	Args.OutsideListener(Where)
	if Runner.IsClosing() then
		return nil, Reasons.Closed
	end
	local Fetched = Services.GetVersion(Target, Version)
	if Fetched.Kind == "Err" then
		return nil, Reasons.Unresolved
	end
	local Raw = if Fetched.Kind == "Ok" then Fetched.Value else nil
	local Answered = Stepping.Run(OldVersion.AnswerOf, Runner.OpenedSetup(Settings.Name), Raw)
	return Answers.ReadAnswer(Answered)
end

function Store.Inspect(self: Store, Key: KeyLike): (unknown, Reason?)
	local Where = "Store:Inspect"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	local Target = Keys.Key(self.Settings, Key, Where)
	Args.OutsideListener(Where)
	local Made: Call = { Kind = "Call", Method = "Inspect" :: "Inspect", CallId = Calls.NewCallId(), Key = Target }
	return Answers.ReadAnswer(Runner.Call(Made):Wait())
end

function Store.DidApply(self: Store, Key: KeyLike, Name: Name, Options: DidApplyOptions?): (unknown, Reason?)
	local Where = "Store:DidApply"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	local Target = Keys.Key(self.Settings, Key, Where)
	local Asked, IsProbe = Args.ProbeName(Name, Options, Where)
	Args.HandleOfKey(Target, Name, Where)
	local Made = DidApplyCallOf(Target, Asked, IsProbe)
	DidApplyOutsideListener(Asked, Where)
	local Answered = Runner.Call(Made):Wait()
	ProbeAdvice.Heard(self.Settings.Name, Asked, IsProbe, Answered)
	return Answers.ReadAnswer(Answered)
end

function Store.Edit(self: Store, Key: KeyLike, Op: Op, Options: EditOptions?): (boolean, Reason?, Info?)
	local Where = "Store:Edit"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self, Settings.Name)
	local Target = Keys.Key(Settings, Key, Where)
	local MustExist, Name = Args.EditOptions(Settings, Options, Where)
	local OpKind, Terms = Args.Op(Settings, Op, Where)
	Args.UntimedWindow(Settings, OpKind, Name, Where)
	Args.OutsideListener(Where)
	local Made: Call = {
		Kind = "Call",
		Method = "Edit" :: "Edit",
		CallId = Calls.NewCallId(),
		Key = Target,
		OpKind = OpKind,
		Terms = Terms,
		MustExist = MustExist,
		Name = Name,
	}
	local Answered, Outcome = Runner.CallWithOutcome(Made):Wait()
	local Ok, Why, Info = Answers.WriteAnswer(Answered)
	return Ok, Why, Answers.WithOutcome(Info, Outcome)
end

function Store.Leg(self: Store, Key: KeyLike, Op: Terms, Options: LegOptions?): Leg
	Args.OutsideStep(LegWhere)
	Stores.CheckLive(self, self.Settings.Name)
	local Given = Rules.Validated(Rules.OrDefault(Options, Rules.NoFields), LegOptionRules, LegWhere)
	local Made: Leg = { Store = self, Key = Key, Op = Op, MustExist = Given.MustExist, Slot = Given.Slot }
	return table.freeze(Made)
end

function Store.Reset(self: Store, Key: KeyLike, Options: ResetOptions?, ...: unknown): (boolean, Cut | Reason, Info?)
	local Where = "Store:Reset"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self, Settings.Name)
	Args.NoNameArguments(Where, ...)
	local Target = Keys.Key(Settings, Key, Where)
	local Given, State = Args.ResetOptions(Settings, Options, Where)
	Args.OutsideListener(Where)
	local Made: Call = {
		Kind = "Call",
		Method = "Reset" :: "Reset",
		CallId = Calls.NewCallId(),
		Key = Target,
		Name = Given,
		Given = State,
	}
	return Answers.CutAnswer(Runner.Call(Made):Wait())
end

function Store.Erase(self: Store, Key: KeyLike, Options: EraseOptions?, ...: unknown): (boolean, Cut | Reason, Info?)
	local Where = "Store:Erase"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self, Settings.Name)
	Args.NoNameArguments(Where, ...)
	Args.Erasable(Settings, Where)
	local Target = Keys.Key(Settings, Key, Where)
	local Given = Args.EraseName(Options, Where)
	Args.OutsideListener(Where)
	local Made: Call =
		{ Kind = "Call", Method = "Erase" :: "Erase", CallId = Calls.NewCallId(), Key = Target, Name = Given }
	return Answers.CutAnswer(Runner.Call(Made):Wait())
end

function Store.Losses(self: Store, Key: KeyLike): (LossRecords?, Reason?)
	local Where = "Store:Losses"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	local Target = Keys.Key(self.Settings, Key, Where)
	Args.OutsideListener(Where)
	local Made: Call = { Kind = "Call", Method = "Losses" :: "Losses", CallId = Calls.NewCallId(), Key = Target }
	return Answers.LossesAnswer(Runner.Call(Made):Wait())
end

function Store.Pending(self: Store, Key: KeyLike): (unknown, Reason?)
	local Where = "Store:Pending"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	local Target = Keys.Key(self.Settings, Key, Where)
	Args.OutsideListener(Where)
	local Made: Call = { Kind = "Call", Method = "Pending" :: "Pending", CallId = Calls.NewCallId(), Key = Target }
	return Answers.ReadAnswer(Runner.Call(Made):Wait())
end

function Store.Resettle(self: Store, Key: KeyLike, ...: unknown): (boolean, Reason?, Info?)
	local Where = "Store:Resettle"
	Args.OutsideStep(Where)
	Stores.CheckLive(self, self.Settings.Name)
	Args.NoOptions(Where, ...)
	local Target = Keys.Key(self.Settings, Key, Where)
	Args.OutsideListener(Where)
	local Made: Call = { Kind = "Call", Method = "Resettle" :: "Resettle", CallId = Calls.NewCallId(), Key = Target }
	return Answers.Plain(Runner.Call(Made):Wait())
end

function Store.Follow(self: Store, Key: KeyLike): Observer<unknown>
	Args.OutsideStep(FollowWhere)
	Stores.CheckLive(self, self.Settings.Name)
	local Target = Keys.Key(self.Settings, Key, FollowWhere)
	local Made = FollowOf(self, Target):Map(Answers.FollowValue)
	self.Follows[Made] = true
	return Made
end

function Store.Stale(self: Store): Observer<string | number>
	local Where = "Store:Stale"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self, Settings.Name)
	AskStale()
	local Made = Streams.Stales(Settings.Name):Map(function(Key: StoreKey): string | number
		return Keys.GameKeyOf(Settings.Keys, Key)
	end)
	self.Stales[Made] = true
	return Made
end

function Store.Bump(
	self: Store,
	Total: string,
	Amount: number,
	Options: BumpOptions?,
	...: unknown
): (boolean, Reason?, Info?)
	local Where = "Store:Bump"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self, Settings.Name)
	Args.NoNameArguments(Where, ...)
	local Declared = QuantityArgs.TotalOf(Settings, Total, Where)
	local Bumped = QuantityArgs.BumpAmount(Declared, Amount, Where)
	local Given = Args.BumpName(Options, Where)
	Args.OutsideListener(Where)
	local Made: Call = {
		Kind = "Call",
		Method = "Bump" :: "Bump",
		CallId = Calls.NewCallId(),
		Store = Settings.Name,
		Scope = ShellSetup.StoreScope,
		Total = Declared,
		Amount = Bumped,
		Name = Given,
		Fraction = Platform.Fraction(),
	}
	local Answered, Outcome = Runner.CallWithOutcome(Made):Wait()
	local Ok, Why, Info = Answers.Plain(Answered)
	return Ok, Why, Answers.WithOutcome(Info, Outcome)
end

function Store.Total(self: Store, Name: string, MaxAge: number?): (unknown, Reason?)
	return Quantity.AskTotal(self, self.Settings, Name, nil, MaxAge, "Store:Total")
end

function Store.Quantity(self: Store, Name: string): Quantity
	local Where = "Store:Quantity"
	Args.OutsideStep(Where)
	local Settings = self.Settings
	Stores.CheckLive(self, Settings.Name)
	local Declaration = QuantityArgs.QuantityOf(Settings, Name, Where)
	local Cached = self.Quantities[Declaration.Name]
	if Cached ~= nil then
		return Cached
	end
	local Made = Quantity.New(self, Settings, Declaration)
	self.Quantities[Declaration.Name] = Made
	return Made
end

function Store.Destroy(self: Store): ()
	local Where = "Store:Destroy"
	Args.OutsideStep(Where)
	local Name = self.Settings.Name
	Stores.CheckNotDestroying(self, Name)
	Args.OutsideListener(Where)
	Stores.MarkDestroying(self)
	local Limits = Runner.OpenedSetup(Name).Limits
	local UnknownCount = Sessions.ReleaseAll(self, Limits.ShutdownSeconds - Limits.Jump)
	if UnknownCount > 0 then
		warn(FatesUnknown(Name, UnknownCount))
	end
	EndEach(self.Follows)
	EndEach(self.Stales)
	Stores.Unregister(self)
end

Store.Load = Sessions.Load
Store.Unload = Sessions.Unload
Store.Get = Sessions.Get
Store.Expect = Sessions.Expect
Store.IsLoaded = Sessions.IsLoaded
Store.WaitForLoaded = Sessions.WaitForLoaded
Store.Read = Sessions.Read

return Store
