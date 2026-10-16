--!strict
--!optimize 2

--[=[
	Stamps: the seals this server stamps or watches (cuts sheets 5.3, 8.4, 8.5): a left over seal shown, the removal
	after a stamp lands, the sealer's check at SealAge, a helper sealer's stamp at W[cut] for an rt it never removed.
	One stamp per key is out at a time; none before the server number or past the close deadline.

	Return type: A plain table with StampFor, AfterSeal, WatchHelperSeal, OnStampResult, OnCheckRead, OnClock,
	AfterEvent and NextWake.
	Example usage:
		Stamps.AfterEvent(State, Clock, Commands)
--]=]

local Cache = require("../../Reading/Cache")
local Closing = require("../../Sessions/Closing")
local Composed = require("../../Composed")
local CutState = require("../State")
local Events = require("../../Events")
local Lookup = require("../../Stored/Lookup")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Removal = require("./Removal")
local SealItems = require("../../Stored/Items/Seal")
local Shapes = require("../../Shapes")
local Sorted = require("../../Sorted")
local Value = require("../../Stored/Value")

type Command = Events.Command
type Outcome = Events.Outcome
type ReadOutcome = Events.ReadOutcome
type StoreKey = Names.StoreKey
type Limits = Shapes.Limits
type Request = Shapes.Request
type Seal = SealItems.Seal
type State = Composed.State
type CutCall = CutState.CutCall
type Purpose = CutState.Purpose
type SealCheck = CutState.SealCheck
type SealWatch = CutState.SealWatch

local IsSameName = Lookup.IsSameName

local function LimitsOf(State: State, Key: StoreKey): Limits
	return Cache.StoreOf(State.Server, Key).Setup.Limits
end

local function StampFor(
	State: State,
	Key: StoreKey,
	RemovalStamp: number,
	CallId: number?,
	Clock: number,
	Commands: { Command }
): boolean
	local Text = Names.KeyText(Key)
	if State.Cuts.Stamping[Text] ~= nil or Closing.IsPastDeadline(State.Sessions, Clock) then
		return false
	end
	local Purpose: Purpose = { Kind = "SealStamp", Key = Key, RemovalStamp = RemovalStamp, CallId = CallId }
	local RequestId = CutState.NewRequest(State.Server, State.Cuts, Purpose)
	State.Cuts.Stamping[Text] = RequestId
	local Stamp: Request =
		{ Kind = "SealStamp", RemovalStamp = RemovalStamp, Server = Numbers.ServerNumberOf(State.Server) }
	local Update: Command = { Kind = "Update", RequestId = RequestId, Target = Key, Request = Stamp }
	table.insert(Commands, Update)
	return true
end

local function Watch(State: State, Key: StoreKey, Sealed: Seal, Kind: "Check" | "Stamp", Age: number)
	local Watched: SealWatch = {
		Key = Key,
		Name = Sealed.Name,
		RemovalStamp = Sealed.RemovalStamp,
		At = Sealed.RemovalStamp + Age,
		Kind = Kind,
	}
	State.Cuts.Watches[Names.KeyText(Key)] = Watched
end

local function WatchCheck(State: State, Key: StoreKey, Sealed: Seal)
	Watch(State, Key, Sealed, "Check", LimitsOf(State, Key).SealAge)
end

local function IsSealedByThisServer(State: State, Sealed: Seal): boolean
	return Sealed.Sealer == Numbers.ServerNumberOf(State.Server)
end

local function WatchHelperSeal(State: State, Key: StoreKey, Sealed: Seal)
	local IsRemovalSent = Removal.WasSent(State, Key, Sealed.Name, Sealed.RemovalStamp)
	if IsSealedByThisServer(State, Sealed) and not IsRemovalSent then
		Watch(State, Key, Sealed, "Stamp", LimitsOf(State, Key).CutWindow)
	end
end

local function AfterSeal(State: State, Cutting: CutCall, Sealed: Seal, Clock: number, Commands: { Command })
	if Cutting.Role ~= "Cutter" or not IsSealedByThisServer(State, Sealed) then
		return
	end
	Removal.SendRemoval(State, Cutting.Key, Sealed.Name, Sealed.RemovalStamp, Clock, Commands)
	WatchCheck(State, Cutting.Key, Sealed)
end

local function AskCheck(State: State, Watched: SealWatch, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return
	end
	local Check: SealCheck =
		{ Kind = "SealCheck", Key = Watched.Key, Name = Watched.Name, RemovalStamp = Watched.RemovalStamp }
	local RequestId = CutState.NewRequest(State.Server, State.Cuts, Check)
	local Get: Command = { Kind = "Get", RequestId = RequestId, Target = Watched.Key }
	table.insert(Commands, Get)
end

local function ActOnWatch(State: State, Text: string, Clock: number, Commands: { Command })
	local Watches = State.Cuts.Watches
	local Watched = Watches[Text]
	if Watched == nil or Clock < Watched.At then
		return
	end
	if Watched.Kind == "Check" then
		AskCheck(State, Watched, Clock, Commands)
		Watches[Text] = nil
	elseif StampFor(State, Watched.Key, Watched.RemovalStamp, nil, Clock, Commands) then
		Watches[Text] = nil
	end
end

local function OnStampResult(State: State, Key: StoreKey, Result: Outcome, Clock: number, Commands: { Command })
	local Text = Names.KeyText(Key)
	State.Cuts.Stamping[Text] = nil
	if Result.Kind ~= "Err" then
		local Landed = Result.Note.WrittenValue
		if Landed ~= nil and Landed.Kind == "Sealed" then
			Removal.SendRemoval(State, Key, Landed.Seal.Name, Landed.Seal.RemovalStamp, Clock, Commands)
			WatchCheck(State, Key, Landed.Seal)
		end
	end
	ActOnWatch(State, Text, Clock, Commands)
end

local function OnCheckRead(State: State, Check: SealCheck, Fetched: ReadOutcome, Clock: number, Commands: { Command })
	if Fetched.Kind ~= "Found" then
		return
	end
	local Setup = Cache.StoreOf(State.Server, Check.Key).Setup
	local Held = Value.DecodeValue(Fetched.Value, Setup.Build, Setup.Limits.WindowUnit)
	if Held == nil or Held.Kind ~= "Sealed" then
		return
	end
	local Sealed = Held.Seal
	if not IsSameName(Sealed.Name, Check.Name) or Sealed.RemovalStamp ~= Check.RemovalStamp then
		return
	end
	if StampFor(State, Check.Key, Check.RemovalStamp, nil, Clock, Commands) then
		return
	end
	local Due: SealWatch =
		{ Key = Check.Key, Name = Check.Name, RemovalStamp = Check.RemovalStamp, At = Clock, Kind = "Stamp" }
	State.Cuts.Watches[Names.KeyText(Check.Key)] = Due
end

local function OnClock(State: State, Clock: number, Commands: { Command })
	local function IsDue(Watched: SealWatch): boolean
		return Clock >= Watched.At
	end
	for _, Text in Sorted.SortedDueTexts(State.Cuts.Watches, IsDue) do
		ActOnWatch(State, Text, Clock, Commands)
	end
end

local function AfterEvent(State: State, Clock: number, Commands: { Command })
	local Server = State.Server
	local Seen = Server.SealsSeen
	if next(Seen) == nil or Server.ServerNumber == nil then
		return
	end
	Server.SealsSeen = {}
	for _, Text in Sorted.SortedTexts(Seen) do
		local LeftOver = Seen[Text]
		if SealItems.IsLeftOver(LeftOver, Clock, LimitsOf(State, LeftOver.Key).SealAge) then
			StampFor(State, LeftOver.Key, LeftOver.RemovalStamp, nil, Clock, Commands)
		end
	end
end

local function NextWake(State: State, Clock: number): number?
	local Soonest: number? = nil
	for _, Watched in State.Cuts.Watches do
		Soonest = Composed.EarliestAfter(Soonest, Watched.At, Clock)
	end
	return Soonest
end

return {
	StampFor = StampFor,
	AfterSeal = AfterSeal,
	WatchHelperSeal = WatchHelperSeal,
	OnStampResult = OnStampResult,
	OnCheckRead = OnCheckRead,
	OnClock = OnClock,
	AfterEvent = AfterEvent,
	NextWake = NextWake,
}
