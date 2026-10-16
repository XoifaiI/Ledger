--!strict
--!optimize 2

--[=[
	Durable: a durable call on one key, Edit or a session's Commit (record sheets 4, 7 and 11). A game name's
	fingerprint is the SHA-256 of the op's kind and terms; once the op joins, SentNames warns of other terms. The
	caller decides Closed. A shard's or part's writer is made paced, by JoinPaced or EnsurePacedWriter. A Commit's op
	gives the state its true is heard with (Answering.AnswerHeard).

	Return type: A plain table with Start, EnsurePacedWriter, JoinPaced and WarnIfOtherTerms, and the DurableCall
	type.
	Example usage:
		local Call = { Method = "Edit" :: "Edit", CallId = 1, Key = Key, OpKind = "d", Terms = {} }
		Durable.Start(State, Call, true, Clock, Commands)
--]=]

local Answering = require("./Answering")
local Cache = require("../Reading/Cache")
local Composed = require("../Composed")
local Events = require("../Events")
local HashInputs = require("../Encoding/HashInputs")
local Json = require("../Encoding/Json")
local Names = require("../Encoding/Names")
local Numbers = require("./Numbers")
local Pacing = require("./Pacing")
local SentNames = require("./SentNames")
local Shapes = require("../Shapes")
local Writers = require("./Writer")

type Command = Events.Command
type GivenName = Events.GivenName
type GameOpName = Names.GameOpName
type OpName = Names.OpName
type StoreKey = Names.StoreKey
type State = Composed.State
type ServerState = Shapes.ServerState
type Setup = Shapes.Setup
type WaitingForm = Shapes.WaitingForm
type WaitingOp = Shapes.WaitingOp
type WriterState = Shapes.WriterState

type HashedName = { read Kind: "Game", read Text: string, read Stamp: number?, read Digest: buffer }
type DrawnName = { read Kind: "Drawn", read Server: number, read Counter: number, read Stamp: number }
type CallName = HashedName | DrawnName

export type DurableCall = {
	read Method: "Edit" | "Commit",
	read CallId: number,
	read Key: StoreKey,
	read OpKind: string,
	read Terms: unknown,
	read Name: GivenName?,
}

local OtherTermsWarning = "the name %s was used with other terms than a call this server sent before. "
	.. "A call that finds the earlier one decided answers Spent."

local function DigestOf(Server: ServerState, Call: DurableCall): buffer
	local Input = HashInputs.OneKeyOpInput(Call.OpKind, Json.CanonicalJson(Call.Terms))
	return HashInputs.Hash(Server.Encoding, Input)
end

local function WarnIfOtherTerms(Server: ServerState, Key: StoreKey, Text: string, Digest: buffer, Commands: { Command })
	local Entry = SentNames.OneKeyEntry(Key, Text)
	local Result = SentNames.Remember(Server, Entry, buffer.tostring(Digest))
	if Result ~= SentNames.Remembered.OtherTerms then
		return
	end
	local Message = string.format(OtherTermsWarning, Text)
	local Warn: Command = { Kind = "Warn", Key = Key, Text = Message }
	table.insert(Commands, Warn)
end

local function HashedNameOf(Server: ServerState, Call: DurableCall): CallName?
	local Name = Call.Name
	if Name == nil or Name.Kind == "Drawn" then
		return Name
	end
	return { Kind = "Game", Text = Name.Text, Stamp = Name.Stamp, Digest = DigestOf(Server, Call) }
end

local function FormOf(Name: CallName?): WaitingForm
	if Name == nil then
		return { Kind = "Minted" }
	end
	if Name.Kind == "Drawn" then
		local Drawn: OpName = { Kind = "Drawn", Server = Name.Server, Counter = Name.Counter }
		return { Kind = "Timed", Name = Drawn, Stamp = Name.Stamp }
	end
	local Game: GameOpName = {
		Kind = "Game",
		Text = Name.Text,
		Fingerprint = HashInputs.NameFingerprint(Name.Digest),
	}
	if Name.Stamp == nil then
		return { Kind = "Untimed", Name = Game }
	end
	return { Kind = "Timed", Name = Game, Stamp = Name.Stamp }
end

local function JoinOp(State: State, Key: StoreKey, Waiting: WaitingOp, Setup: Setup, Commands: { Command }): boolean
	local Server = State.Server
	local Existing = Writers.WriterFor(Server, Key)
	if Existing ~= nil then
		local Shed = Writers.Shed(Existing, Waiting, Setup.Limits)
		if Shed ~= nil then
			Answering.AnswerWaitingFailed(Server, Commands, Key, Waiting, Shed)
			return false
		end
	end
	local Writer = Writers.WriterOrNew(Server, Key)
	if Writers.Join(Writer, Waiting, Setup.Limits).Kind == "FirstWaiting" then
		table.insert(Commands, Numbers.AskWriterNumber(Server, Key, Setup.Limits))
	end
	Composed.NoteSendableAt(State, Writer.Text, Key)
	return true
end

local function EnsurePacedWriter(
	Server: ServerState,
	Key: StoreKey,
	Setup: Setup,
	IsShard: boolean,
	Fraction: number,
	Clock: number
): WriterState
	local Existing = Writers.WriterFor(Server, Key)
	if Existing ~= nil then
		return Existing
	end
	local Made = Writers.NewWriter(Server, Key)
	Made.Paced = Pacing.NewPaced(IsShard, Clock, Fraction, Setup.Limits)
	return Made
end

local function JoinPaced(
	State: State,
	Key: StoreKey,
	Waiting: WaitingOp,
	Setup: Setup,
	IsShard: boolean,
	Fraction: number,
	Clock: number,
	Commands: { Command }
): boolean
	EnsurePacedWriter(State.Server, Key, Setup, IsShard, Fraction, Clock)
	return JoinOp(State, Key, Waiting, Setup, Commands)
end

local function Start(State: State, Call: DurableCall, MustExist: boolean, JoinedAt: number, Commands: { Command })
	local Server = State.Server
	local Setup = Cache.StoreOf(Server, Call.Key).Setup
	local Name = HashedNameOf(Server, Call)
	local Waiting: WaitingOp = {
		Form = FormOf(Name),
		OpKind = Call.OpKind,
		Terms = Call.Terms,
		JoinedAt = JoinedAt,
		MustExist = MustExist,
		Size = Json.Size(Call.Terms),
		CallId = Call.CallId,
		IsStep = false,
		GivesState = Call.Method == "Commit",
	}
	if not JoinOp(State, Call.Key, Waiting, Setup, Commands) then
		return
	end
	if Name ~= nil and Name.Kind == "Game" then
		WarnIfOtherTerms(Server, Call.Key, Name.Text, Name.Digest, Commands)
	end
end

return {
	Start = Start,
	EnsurePacedWriter = EnsurePacedWriter,
	JoinPaced = JoinPaced,
	WarnIfOtherTerms = WarnIfOtherTerms,
}
