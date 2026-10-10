--!strict
--!optimize 2

--[=[
	Composed: the state that step keeps, changed in place: the server's state, its sessions, the reads and flushes in
	flight, the held calls, the transaction, cut, extras and hot states, the kept wake and the requests out by id.

	A replay passes its own server to NewState. Opening a store forgets the kept wake. Its first Limits recorded stay.

	Return type: A plain table of functions, and the State, Held, HeldCall, IncarnationRead, Flush, NumberRetry,
	WriterRequest and KeptWake types.
	Example usage:
		local State = Composed.NewState(Composed.NewServer(JobId, Encoding))
		Composed.OpenStore(State, Setup)
--]=]

local Closing = require("./Sessions/Closing")
local CutState = require("./Cuts/State")
local Events = require("./Events")
local ExtrasState = require("./Extras/State")
local HashInputs = require("./Encoding/HashInputs")
local HotState = require("./Hot/State")
local Names = require("./Encoding/Names")
local Reads = require("./Reading/Reads")
local Recency = require("./Recency")
local Record = require("./Constants/Record")
local Session = require("./Sessions/Session")
local Shapes = require("./Shapes")
local Showables = require("./Reading/Showables")
local TxState = require("./Tx/State")

type Call = Events.Call
type CutsState = CutState.CutsState
type Encoding = HashInputs.Encoding
type ExtrasState = ExtrasState.ExtrasState
type HotState = HotState.HotState
type StoreKey = Names.StoreKey
type ReadContext = Reads.ReadContext
type Limits = Shapes.Limits
type Setup = Shapes.Setup
type Opened = Reads.Opened
type OpenedEmpty = Reads.OpenedEmpty
type ReadOut = Reads.ReadOut
type SessionState = Session.SessionState
type TxState = TxState.TxState
type NumberAsk = Shapes.NumberAsk
type ServerState = Shapes.ServerState
type Served = Showables.Served

export type HeldCall = { read Kind: "Held", read Call: Call, read At: number }

export type Held = HeldCall | Opened | OpenedEmpty

export type IncarnationRead = { read Key: StoreKey, RequestId: number?, ErrorsInARow: number, RetryAt: number? }

export type Flush = { read CallId: number, read Key: StoreKey, RequestId: number?, read Deadline: number }

export type NumberRetry = { ErrorsInARow: number, RetryAt: number?, Asks: { NumberAsk }, IsUnusableWarned: boolean }

export type WriterRequest = { read Store: string, read Text: string }

export type KeptWake = {
	IsKnown: boolean,
	At: number?,
	ShedAt: number?,
	KeyAt: { [string]: number },
	KeyShedAt: { [string]: number },
	KeyOf: { [string]: StoreKey },
}

export type State = {
	Server: ServerState,
	Sessions: SessionState,
	Reads: { [number]: ReadOut },
	Incarnations: { [string]: IncarnationRead },
	Flushing: { Flush },
	Held: { Held },
	NumberRetry: NumberRetry,
	Sendable: { [string]: StoreKey },
	TimersMoved: { [string]: StoreKey },
	Wake: KeptWake,
	WriterRequests: { [number]: WriterRequest },
	IncarnationReads: { [number]: string },
	Tx: TxState,
	Cuts: CutsState,
	Extras: ExtrasState,
	Hot: HotState,
}

local function NewServer(JobId: string, Encoding: Encoding): ServerState
	return {
		JobId = JobId,
		Encoding = Encoding,
		NumbersAsked = {},
		Counter = 0,
		RequestCounter = 0,
		HelperCounter = 0,
		Caches = {},
		CacheOrder = Recency.New(),
		Unserved = { States = {}, Order = Recency.New() },
		Shown = {
			Order = Recency.New(),
			Keys = {},
			Counts = {},
			Incarnations = {},
			LastShown = {},
			Bits = buffer.create(Record.ShownBitCount // Record.BitsPerByte),
		},
		SentNames = {},
		SentOrder = Recency.New(),
		Stores = {},
		Rides = {},
		WorkSeen = {},
		SealsSeen = {},
		Landed = {},
		StepOut = {},
	}
end

local function NewState(Server: ServerState): State
	return {
		Server = Server,
		Sessions = Session.NewState(),
		Reads = {},
		Incarnations = {},
		Flushing = {},
		Held = {},
		NumberRetry = { ErrorsInARow = 0, Asks = {}, IsUnusableWarned = false },
		Sendable = {},
		TimersMoved = {},
		Wake = { IsKnown = false, KeyAt = {}, KeyShedAt = {}, KeyOf = {} },
		WriterRequests = {},
		IncarnationReads = {},
		Tx = TxState.NewState(),
		Cuts = CutState.NewState(),
		Extras = ExtrasState.NewState(),
		Hot = HotState.NewState(),
	}
end

local function RecordServerLimits(State: State, Limits: Limits)
	local Server = State.Server
	if Server.Limits == nil then
		Server.Limits = Limits
	end
end

local function OpenStore(State: State, Setup: Setup)
	State.Server.Stores[Setup.Store] = { Setup = Setup, Writers = {} }
	RecordServerLimits(State, Setup.Limits)
	State.Wake.IsKnown = false
end

local function ServedOf(State: State): Served
	return { Open = State.Sessions.Open, Followers = State.Extras.Followers, CopyHolders = State.Extras.CopyHolders }
end

local function ReadContextAt(State: State, Clock: number): ReadContext
	return {
		Clock = Clock,
		Served = ServedOf(State),
		IsSilent = Closing.IsPastDeadline(State.Sessions, Clock),
		Aborted = TxState.AbortedUses(State.Tx),
	}
end

local function NoteTimersMovedAt(State: State, Text: string, Key: StoreKey)
	State.TimersMoved[Text] = Key
end

local function NoteTimersMoved(State: State, Key: StoreKey)
	NoteTimersMovedAt(State, Names.KeyText(Key), Key)
end

local function NoteSendableAt(State: State, Text: string, Key: StoreKey)
	State.Sendable[Text] = Key
	NoteTimersMovedAt(State, Text, Key)
end

local function NoteSendable(State: State, Key: StoreKey)
	NoteSendableAt(State, Names.KeyText(Key), Key)
end

local function OpenCount(State: State): number
	return TxState.OpenCount(State.Tx)
		+ CutState.OpenCount(State.Cuts)
		+ ExtrasState.OpenCount(State.Extras)
		+ HotState.OpenCount(State.Hot, State.Server)
end

local function IsReached(At: number?, Clock: number): boolean
	return At ~= nil and Clock >= At
end

local function EarliestAfter(Soonest: number?, At: number?, Clock: number): number?
	if At == nil or At <= Clock then
		return Soonest
	end
	if Soonest == nil or At < Soonest then
		return At
	end
	return Soonest
end

return {
	NewServer = NewServer,
	NewState = NewState,
	RecordServerLimits = RecordServerLimits,
	OpenStore = OpenStore,
	ServedOf = ServedOf,
	ReadContextAt = ReadContextAt,
	NoteSendable = NoteSendable,
	NoteSendableAt = NoteSendableAt,
	NoteTimersMoved = NoteTimersMoved,
	NoteTimersMovedAt = NoteTimersMovedAt,
	OpenCount = OpenCount,
	IsReached = IsReached,
	EarliestAfter = EarliestAfter,
}
