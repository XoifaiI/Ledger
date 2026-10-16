--!strict
--!optimize 2

--[=[
	Numbers: the server's number from a counter key the JobId chooses, request ids, negative helper call ids (record
	sheet 5, Format.md 11). LearnStored and LearnFromNote own what a read or note teaches: a key's cache entry (an id,
	legacy or absent), gate and left over seals; none from unreadable values. A key holding no value forgets old
	incarnations' state (Showables). A key heard Behind forgets its shown state and stays marked until a read shows a
	state or no value.

	Return type: A plain table of functions.
	Example usage:
		local Command = Numbers.AskServerNumber(State, RequestId, { Kind = "Life" }, Limits)
--]=]

local Book = require("../Stored/Book")
local Cache = require("../Reading/Cache")
local Events = require("../Events")
local Format = require("../Encoding/Format")
local HashInputs = require("../Encoding/HashInputs")
local JudgingShapes = require("../Judging/Shapes")
local KindSetup = require("../Judging/KindSetup")
local Names = require("../Encoding/Names")
local Record = require("../Constants/Record")
local Seal = require("../Stored/Items/Seal")
local Shapes = require("../Shapes")
local Showables = require("../Reading/Showables")
local Value = require("../Stored/Value")
local Work = require("../Stored/Items/Work")

type Command = Events.Command
type ReadAnswered = Events.ReadAnswered
type Encoding = HashInputs.Encoding
type OpName = Names.OpName
type StoreKey = Names.StoreKey
type Gate = Seal.Gate
type Seal = Seal.Seal
type Limits = Shapes.Limits
type CacheEntry = Shapes.CacheEntry
type Identity = Book.Identity
type Seen = Shapes.Seen
type Setup = Shapes.Setup
type Note = JudgingShapes.Note
type Report = JudgingShapes.Report
type NumberAsk = Shapes.NumberAsk
type ServerState = Shapes.ServerState
type Kept = Value.Kept
type Mark = Work.Mark
type Value = Value.Value
type Unreadable = Value.Unreadable

export type StoredRead = { read Kind: "Kept", read Kept: Kept } | { read Kind: "Nothing" } | Unreadable

local VarintLimit = Record.VarintLimit

local CounterStartBytes = 16

local RoutingFault = "Numbers: this call is never made."
local NotCounterText = "a counter holds a value that is not text, which the counter's own writer never writes"
local NoServerNumber = `{RoutingFault} The server number is read only once it has landed.`
local UnaskedNumber = `{RoutingFault} A counter answered that nothing asked.`

local function CounterIndex(Encoding: Encoding, JobId: string, Limits: Limits): number
	local Digest = HashInputs.Hash(Encoding, HashInputs.CounterInput(JobId))
	return HashInputs.ChoiceNumber(Digest) % Limits.CounterKeyCount
end

local function CounterKey(Index: number): StoreKey
	return { Store = Record.CounterStore, Scope = Record.CounterScope, Key = tostring(Index) }
end

local function CounterValue(Count: number): string
	local Out = Format.NewWriter(CounterStartBytes)
	Format.WriteVarint(Out, Count)
	return Format.ToString(Out)
end

local function ReadCounterValue(Stored: unknown): number
	if Stored == nil then
		return 0
	end
	if type(Stored) ~= "string" then
		return Format.Malformed(NotCounterText)
	end
	return Format.ReadWhole(Stored, Format.ReadVarint)
end

local function DecodeCounterValue(Stored: unknown): number?
	local Succeeded, Count = pcall(ReadCounterValue, Stored)
	if not Succeeded then
		return nil
	end
	return Count
end

local function ServerNumber(Index: number, Count: number, Limits: Limits): number
	return Limits.CounterKeyCount * Count + Index
end

local function CountMost(Limits: Limits): number
	return (VarintLimit - Limits.CounterKeyCount) // Limits.CounterKeyCount
end

local function AddOne(Stored: unknown, Limits: Limits): string?
	local Count = DecodeCounterValue(Stored)
	if Count == nil or Count + 1 > CountMost(Limits) then
		return nil
	end
	return CounterValue(Count + 1)
end

local function NewRequestId(State: ServerState): number
	State.RequestCounter += 1
	return State.RequestCounter
end

local function NewHelperId(State: ServerState): number
	State.HelperCounter += 1
	return -State.HelperCounter
end

local function CounterKeyOf(State: ServerState, Limits: Limits): StoreKey
	return CounterKey(CounterIndex(State.Encoding, State.JobId, Limits))
end

local function AskServerNumber(State: ServerState, RequestId: number, Ask: NumberAsk, Limits: Limits): Command
	local function Add(Stored: unknown): string?
		return AddOne(Stored, Limits)
	end
	State.NumbersAsked[RequestId] = Ask
	return { Kind = "Count", RequestId = RequestId, Target = CounterKeyOf(State, Limits), Add = Add }
end

local function AskWriterNumber(State: ServerState, Key: StoreKey, Limits: Limits): Command
	local Ask: NumberAsk = { Kind = "Writer", Key = Key }
	return AskServerNumber(State, NewRequestId(State), Ask, Limits)
end

local function ServerNumberOf(State: ServerState): number
	local ServerNumber = State.ServerNumber
	if ServerNumber == nil then
		error(NoServerNumber)
	end
	return ServerNumber
end

local function DrawFreshId(State: ServerState): Identity
	local ServerNumber = ServerNumberOf(State)
	State.Counter += 1
	return { Server = ServerNumber, Counter = State.Counter }
end

local function DrawnName(State: ServerState): OpName
	local Fresh = DrawFreshId(State)
	return { Kind = "Drawn", Server = Fresh.Server, Counter = Fresh.Counter }
end

local function EntryFor(State: ServerState, Key: StoreKey): CacheEntry
	local Entry, LostResumed = Cache.CacheEntry(State, Key)
	if LostResumed ~= nil and LostResumed.WriterId == State.WriterNumber then
		State.WriterNumber = nil
	end
	return Entry
end

local function SeenOf(Identity: Identity?, ShowsKey: boolean): Seen
	if Identity ~= nil then
		return { Kind = "Known", Identity = Identity }
	end
	if ShowsKey then
		return { Kind = "Legacy" }
	end
	return { Kind = "Absent" }
end

local function RaiseHorizon(Entry: CacheEntry, Horizon: number?)
	if Horizon ~= nil and (Entry.Horizon == nil or Horizon > Entry.Horizon) then
		Entry.Horizon = Horizon
	end
end

local function Learn(Entry: CacheEntry, Key: StoreKey, Setup: Setup, Horizon: number?, Seen: Seen)
	RaiseHorizon(Entry, Horizon)
	if KindSetup.IsErasableKey(Setup, Key) then
		Entry.Seen = Seen
	end
end

local function FillEntry(
	Entry: CacheEntry,
	Key: StoreKey,
	Setup: Setup,
	Horizon: number?,
	Identity: Identity?,
	ShowsKey: boolean
)
	if Entry.Seen == nil then
		Learn(Entry, Key, Setup, Horizon, SeenOf(Identity, ShowsKey))
		return
	end
	RaiseHorizon(Entry, Horizon)
end

local function SeeSeal(State: ServerState, Key: StoreKey, Sealed: Seal)
	State.SealsSeen[Names.KeyText(Key)] = { Key = Key, RemovalStamp = Sealed.RemovalStamp }
end

local function LearnWorkAndGate(State: ServerState, Entry: CacheEntry, Key: StoreKey, Items: { Mark }, Gate: Gate?)
	Entry.Work = Items
	Entry.Gate = Gate
	State.WorkSeen[Names.KeyText(Key)] = Key
end

local function LearnStored(
	State: ServerState,
	Key: StoreKey,
	Setup: Setup,
	Fetched: ReadAnswered,
	Clock: number
): StoredRead
	local Stored: Value? = nil
	if Fetched.Kind == "Found" then
		local KeySetup = KindSetup.SetupFor(Setup, Cache.KindOfKey(Key))
		local Decoded = Value.DecodeStored(Fetched.Value, KeySetup.Build, KeySetup.Limits.WindowUnit)
		if Decoded.Kind == "Unreadable" then
			return Decoded
		end
		Stored = Decoded
	end
	local Entry = EntryFor(State, Key)
	if Stored == nil or Stored.Kind == "Sealed" then
		Learn(Entry, Key, Setup, nil, SeenOf(nil, false))
		Showables.Forget(State, Key)
		Entry.IsBehind = nil
		Entry.Gate = nil
		local Found: Value? = Stored
		if Found ~= nil and Found.Kind == "Sealed" and Seal.IsLeftOver(Found.Seal, Clock, Setup.Limits.SealAge) then
			SeeSeal(State, Key, Found.Seal)
		end
		return { Kind = "Nothing" }
	end
	Learn(Entry, Key, Setup, Stored.Book.Horizon, SeenOf(Stored.Book.Identity, true))
	LearnWorkAndGate(State, Entry, Key, Stored.Book.Work, Stored.Book.Gate)
	return { Kind = "Kept", Kept = Stored }
end

local function FindReport(Note: Note, Kind: string): Report?
	local Probed = Note.ProbeReport
	if Probed ~= nil and Probed.Kind == Kind then
		return Probed
	end
	for _, Report in Note.Reports do
		if Report.Kind == Kind then
			return Report
		end
	end
	for _, Report in Note.EndReports do
		if Report.Kind == Kind then
			return Report
		end
	end
	return nil
end

local function LeftOverSealOf(Note: Note): Seal?
	local Found = FindReport(Note, "Missing")
	if Found ~= nil and Found.Kind == "Missing" and Found.IsLeftOver then
		return Found.Seal
	end
	return nil
end

local function SeeLeftOver(State: ServerState, Key: StoreKey, Note: Note)
	local LeftOver = LeftOverSealOf(Note)
	if LeftOver ~= nil then
		SeeSeal(State, Key, LeftOver)
	end
end

local function HoldsNoValue(Note: Note): boolean
	local Written = Note.WrittenValue
	if Written ~= nil and Written.Kind == "Sealed" then
		return true
	end
	local Found = FindReport(Note, "Missing")
	return Found ~= nil and Found.Kind == "Missing" and Found.Identity == nil and not Found.IsLegacy
end

local function FileLanded(State: ServerState, Key: StoreKey, Note: Note)
	local Written = Note.WrittenValue
	if Written ~= nil and Written.Kind == "Kept" then
		table.insert(State.Landed, { Key = Key, Written = Written, Bytes = Note.WrittenBytes })
	end
end

local function LearnFromNote(State: ServerState, Entry: CacheEntry, Key: StoreKey, Setup: Setup, Note: Note)
	FileLanded(State, Key, Note)
	if FindReport(Note, "Unreadable") ~= nil then
		return
	end
	Learn(Entry, Key, Setup, Note.Horizon, SeenOf(Note.Identity, Note.ShowsKey))
	LearnWorkAndGate(State, Entry, Key, Note.Work, Note.Gate)
	SeeLeftOver(State, Key, Note)
	if HoldsNoValue(Note) then
		Showables.Forget(State, Key)
		Entry.IsBehind = nil
	end
end

local function HearBehind(State: ServerState, Key: StoreKey)
	EntryFor(State, Key).IsBehind = true
	Showables.Forget(State, Key)
end

local function IsKnownBehind(State: ServerState, Key: StoreKey): boolean
	local Entry = Cache.FindEntry(State, Key)
	return Entry ~= nil and Entry.IsBehind == true
end

local function TakeServerNumber(
	State: ServerState,
	RequestId: number,
	Written: string?,
	Limits: Limits
): (NumberAsk, number?)
	local Ask = State.NumbersAsked[RequestId]
	if Ask == nil then
		error(UnaskedNumber)
	end
	State.NumbersAsked[RequestId] = nil
	if Written == nil then
		return Ask, nil
	end
	local Index = CounterIndex(State.Encoding, State.JobId, Limits)
	local Number = ServerNumber(Index, ReadCounterValue(Written), Limits)
	if Ask.Kind == "Life" then
		State.ServerNumber = Number
		State.WriterNumber = Number
	elseif Ask.Kind == "Shared" then
		State.WriterNumber = Number
	end
	return Ask, Number
end

return {
	CounterKey = CounterKey,
	CounterValue = CounterValue,
	ReadCounterValue = ReadCounterValue,
	ServerNumber = ServerNumber,
	CounterKeyOf = CounterKeyOf,
	NewRequestId = NewRequestId,
	NewHelperId = NewHelperId,
	AskServerNumber = AskServerNumber,
	AskWriterNumber = AskWriterNumber,
	ServerNumberOf = ServerNumberOf,
	DrawFreshId = DrawFreshId,
	DrawnName = DrawnName,
	EntryFor = EntryFor,
	FillEntry = FillEntry,
	LearnStored = LearnStored,
	SeeLeftOver = SeeLeftOver,
	LearnFromNote = LearnFromNote,
	HearBehind = HearBehind,
	IsKnownBehind = IsKnownBehind,
	TakeServerNumber = TakeServerNumber,
}
