--!strict
--!optimize 2

--[=[
	Bump: a Bump call and its shard (extras sheet E2 steps 1 to 3). Unnamed, the op is minted on the server's
	home shard. Named, with its first send time, it is timed on the shard the name hashes to, fingerprinted by
	total and amount. It joins that shard's paced writer; a game name is remembered once its op joins.

	Return type: A plain table of functions.
	Example usage:
		if Bump.CanStart(Server, Call) then Bump.StartBump(State, Call, Arrived, Clock, Commands) end
--]=]

local Cache = require("../../Reading/Cache")
local Composed = require("../../Composed")
local Durable = require("../../Writing/Durable")
local Events = require("../../Events")
local Extras = require("../../Constants/Extras")
local ExtrasShapes = require("../Shapes")
local HashInputs = require("../../Encoding/HashInputs")
local InFlight = require("../../Reading/InFlight")
local Json = require("../../Encoding/Json")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Shapes = require("../../Shapes")
local Shard = require("./Shard")

type Encoding = HashInputs.Encoding
type GameOpName = Names.GameOpName
type StoreKey = Names.StoreKey
type BumpCall = ExtrasShapes.BumpCall
type TotalDeclaration = ExtrasShapes.TotalDeclaration
type ServerState = Shapes.ServerState
type State = Composed.State
type WaitingForm = Shapes.WaitingForm
type WaitingOp = Shapes.WaitingOp
type Command = Events.Command

type BumpName = { read Kind: "Minted" } | { read Kind: "Named", read Text: string, read Stamp: number }

local MintedName: BumpName = table.freeze({ Kind = "Minted" :: "Minted" })
local MintedForm: WaitingForm = table.freeze({ Kind = "Minted" :: "Minted" })

local ModuleName = "Bump"
local RoutingFault = `{ModuleName}: this call is never made.`
local DrawnNameGiven = `{RoutingFault} A Bump takes a game name or none, and Api/Validate throws on a drawn one.`
local NoFirstSendTime =
	`{RoutingFault} A Bump game name carries its first send time, and Api/Validate throws without it.`

local function HomeShard(Encoding: Encoding, Total: TotalDeclaration, ServerNumber: number): number
	local Digest = HashInputs.Hash(Encoding, HashInputs.HomeShardInput(Total.Name, Total.KeyCount, ServerNumber))
	return HashInputs.ChoiceNumber(Digest) % Total.KeyCount
end

local function NamedShard(Encoding: Encoding, Total: TotalDeclaration, Name: string): number
	local Digest = HashInputs.Hash(Encoding, HashInputs.BumpShardInput(Name))
	return HashInputs.ChoiceNumber(Digest) % Total.KeyCount
end

local function BumpDigest(Encoding: Encoding, Total: TotalDeclaration, Amount: number): buffer
	return HashInputs.Hash(Encoding, HashInputs.BumpInput(Total.Name, Total.KeyCount, Amount))
end

local function BumpNameOf(Call: BumpCall): BumpName
	local Name = Call.Name
	if Name == nil then
		return MintedName
	end
	if Name.Kind ~= "Game" then
		error(DrawnNameGiven)
	end
	if Name.Stamp == nil then
		error(NoFirstSendTime)
	end
	return { Kind = "Named", Text = Name.Text, Stamp = Name.Stamp }
end

local function ShardIndexOf(Server: ServerState, Call: BumpCall, Name: BumpName): number
	if Name.Kind == "Minted" then
		return HomeShard(Server.Encoding, Call.Total, Numbers.ServerNumberOf(Server))
	end
	return NamedShard(Server.Encoding, Call.Total, Name.Text)
end

local function ShardKeyOf(Server: ServerState, Call: BumpCall, Name: BumpName): StoreKey
	return Shard.ShardKey(Call.Store, Call.Scope, Call.Total, ShardIndexOf(Server, Call, Name))
end

local function NamedForm(Name: string, Stamp: number, Digest: buffer): WaitingForm
	local Game: GameOpName = { Kind = "Game", Text = Name, Fingerprint = HashInputs.NameFingerprint(Digest) }
	return { Kind = "Timed", Name = Game, Stamp = Stamp }
end

local function CanStart(Server: ServerState, Call: BumpCall): boolean
	Shard.BumpTerms(Call.Amount, Call.Total.KeyCount)
	local Name = BumpNameOf(Call)
	if Server.ServerNumber == nil then
		return false
	end
	return InFlight.CanWrite(Server, ShardKeyOf(Server, Call, Name))
end

local function JoinBump(
	State: State,
	Key: StoreKey,
	Call: BumpCall,
	Form: WaitingForm,
	Arrived: number,
	Clock: number,
	Commands: { Command }
): boolean
	local Terms = Shard.BumpTerms(Call.Amount, Call.Total.KeyCount)
	local Waiting: WaitingOp = {
		Form = Form,
		OpKind = Extras.BumpOpKind,
		Terms = Terms,
		JoinedAt = Arrived,
		MustExist = false,
		Size = Json.Size(Terms),
		CallId = Call.CallId,
		IsStep = false,
	}
	local Setup = Cache.StoreOf(State.Server, Key).Setup
	return Durable.JoinPaced(State, Key, Waiting, Setup, true, Call.Fraction, Clock, Commands)
end

local function StartBump(State: State, Call: BumpCall, Arrived: number, Clock: number, Commands: { Command })
	local Server = State.Server
	local Name = BumpNameOf(Call)
	local Key = ShardKeyOf(Server, Call, Name)
	if Name.Kind == "Minted" then
		JoinBump(State, Key, Call, MintedForm, Arrived, Clock, Commands)
		return
	end
	local Digest = BumpDigest(Server.Encoding, Call.Total, Call.Amount)
	if JoinBump(State, Key, Call, NamedForm(Name.Text, Name.Stamp, Digest), Arrived, Clock, Commands) then
		Durable.WarnIfOtherTerms(Server, Key, Name.Text, Digest, Commands)
	end
end

return {
	CanStart = CanStart,
	StartBump = StartBump,
}
