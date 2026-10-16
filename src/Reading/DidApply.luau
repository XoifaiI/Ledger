--!strict
--!optimize 2

--[=[
	DidApply: the record's DidApply (record sheet 14), with and without its probe.

	A minted name or Queued handle is answered from its writer: Expired once no longer kept, false once a heard fate
	turned its op away. A game or drawn name is read: Missing on no value, Expired when unkept at or below either
	horizon (Reads). A probe of an untimed name throws: it has no first send time.

	Return type: A plain table with DidApply and DidApplyWithProbe, and the DidApplyCall type.
	Example usage:
		local Out = DidApply.DidApply(State, { CallId = 1, Key = Key, Name = Asked }, Clock, Commands)
--]=]

local Events = require("../Events")
local Names = require("../Encoding/Names")
local Reads = require("./Reads")
local Reasons = require("../Constants/Reasons")
local Replies = require("../Replies")
local Shapes = require("../Shapes")
local Writers = require("../Writing/Writer")

type Answer = Events.Answer
type Command = Events.Command
type Name = Names.Name
type StoreKey = Names.StoreKey
type AskedName = Shapes.AskedName
type Request = Shapes.Request
type ServerState = Shapes.ServerState
type Want = Reads.Want
type ReadOut = Reads.ReadOut

export type DidApplyCall = { read CallId: number, read Key: StoreKey, read Name: AskedName }

local ExpiredAnswer: Answer = table.freeze(Replies.FailedAnswer(Reasons.Expired))
local TurnedAwayAnswer: Answer = table.freeze({ Kind = "Succeeded" :: "Succeeded", Value = false })

local RoutingFault = "DidApply: this call is never made."
local MintedHasNoName = `{RoutingFault} A minted name is answered by its writer, so it has no name to read.`
local UntimedProbe =
	"DidApply: a probe cannot judge an untimed name, which has no first send time. Ask without the probe."

local function StampOfAsked(Asked: AskedName): number?
	if Asked.Kind == "Game" or Asked.Kind == "Drawn" then
		return Asked.Stamp
	end
	return nil
end

local function NameOfAsked(Asked: AskedName): Name
	if Asked.Kind == "Game" then
		return { Kind = "Game", Text = Asked.Text }
	end
	if Asked.Kind == "Drawn" then
		return { Kind = "Drawn", Server = Asked.Server, Counter = Asked.Counter }
	end
	return error(MintedHasNoName)
end

local function MintedAnswer(State: ServerState, Key: StoreKey, WriterId: number, Sequence: number): Answer
	local Writer = Writers.WriterFor(State, Key)
	if Writer == nil or Writer.WriterId ~= WriterId or Sequence < Writer.FirstSequence then
		return ExpiredAnswer
	end
	local NotTook = Writer.NotTook[Sequence]
	if NotTook == "TurnedAway" then
		return TurnedAwayAnswer
	end
	if NotTook == "Unknown" then
		return Reads.UnresolvedAnswer
	end
	if Sequence <= Writer.Acknowledged then
		return Reads.TookAnswer
	end
	local Found = Writers.FindOp(Writer.Queue, Sequence)
	if Found == nil or not Found.IsHeard then
		return Reads.UnresolvedAnswer
	end
	return Reads.TookAnswer
end

local function QueuedAnswer(State: ServerState, Key: StoreKey, CallId: number): Answer
	local Writer = Writers.WriterFor(State, Key)
	if Writer == nil then
		return ExpiredAnswer
	end
	local Named = Writer.MintedByCall[CallId]
	if Named == nil then
		return Reads.UnresolvedAnswer
	end
	return MintedAnswer(State, Key, Named.WriterId, Named.Sequence)
end

local function StartDidApply(
	State: ServerState,
	Call: DidApplyCall,
	Probe: Request?,
	Clock: number,
	Commands: { Command }
): ReadOut
	local Want: Want =
		{ Kind = "DidApply", Name = NameOfAsked(Call.Name), Stamp = StampOfAsked(Call.Name), Probe = Probe }
	return Reads.StartWant(State, Call, Want, Clock, Commands)
end

local function DidApply(State: ServerState, Call: DidApplyCall, Clock: number, Commands: { Command }): ReadOut?
	local Asked = Call.Name
	if Asked.Kind == "Minted" then
		Replies.Reply(Commands, Call.CallId, MintedAnswer(State, Call.Key, Asked.WriterId, Asked.Sequence))
		return nil
	end
	if Asked.Kind == "Queued" then
		Replies.Reply(Commands, Call.CallId, QueuedAnswer(State, Call.Key, Asked.CallId))
		return nil
	end
	return StartDidApply(State, Call, nil, Clock, Commands)
end

local function DidApplyWithProbe(State: ServerState, Call: DidApplyCall, Clock: number, Commands: { Command }): ReadOut?
	local Asked = Call.Name
	if Asked.Kind == "Minted" or Asked.Kind == "Queued" then
		return DidApply(State, Call, Clock, Commands)
	end
	if Asked.Stamp == nil then
		error(UntimedProbe)
	end
	local Probe: Request = { Kind = "Probe", Name = NameOfAsked(Asked), Stamp = Asked.Stamp }
	return StartDidApply(State, Call, Probe, Clock, Commands)
end

return {
	DidApply = DidApply,
	DidApplyWithProbe = DidApplyWithProbe,
}
