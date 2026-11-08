--!strict
--!optimize 2

--[=[
	Follow: a followed key's follower (extras sheet E9). A tick reads its home replica's header (Tick.Begin), then
	that replica's parts, so it sends at most 1 + PartsMax gets (L1), and no part read from the close deadline. A
	replica other than 0 that is missing, unreadable, unrefreshed or misses a part sends the next tick to replica
	0; a Peek, which has one tick, reads replica 0 at once. Only replica 0 carries the lease, so only its header
	can show a lapse. A failed read is not a miss: it sends one cold read (Replicas.ColdKeyOf), and the follower
	reads the key itself (KeyPath) only if MemoryStore does not answer that.

	A header still held by this server's own lease, whose holder this server dropped (Copies/Refresh's stop rule),
	refreshes at once rather than waiting for the lease to lapse.

	Return type: A plain table of functions.
	Example usage:
		Follow.OnFollow(State, { Kind = "Call", Method = "Follow", CallId = 4, Key = Key }, 0, Clock, Commands)
--]=]

local Beside = require("../../Trades/Beside")
local Cache = require("../../../Keys/DataStore/Cache")
local Closing = require("../../../Keys/DataStore/Closing")
local Composed = require("../../../Shared/Composed")
local CopyRefresh = require("./Refresh")
local CopyState = require("./State")
local Events = require("../../../Shared/Events")
local Extras = require("../../../Keys/Constants/Extras")
local ExtrasShapes = require("../../../Shared/ReadShapes")
local ExtrasState = require("../State")
local Items = require("./Items")
local KeyPath = require("./KeyPath")
local Names = require("../../../Keys/Encoding/Names")
local Numbers = require("../../../Keys/DataStore/Numbers")
local Reads = require("../../../Keys/DataStore/Reads")
local Replicas = require("./Replicas")
local Replies = require("../../../Shared/Replies")
local Showables = require("../../../Keys/DataStore/Showables")
local Shown = require("../../../Keys/DataStore/Shown")
local Summary = require("../Totals/Summary")
local Tick = require("./Tick")
local Value = require("../../../Keys/Format/Value")
local View = require("../../../Keys/DataStore/View")

type Command = Events.Command
type DecodeOutcome = Events.DecodeOutcome
type MemoryFetched = Events.MemoryFetched
type CopyHeader = ExtrasShapes.CopyHeader
type CopyPart = ExtrasShapes.CopyPart
type FollowCall = ExtrasShapes.FollowCall
type UnfollowCall = ExtrasShapes.UnfollowCall
type Decode = CopyState.Decode
type Follower = CopyState.Follower
type HeaderGet = CopyState.HeaderGet
type PartGet = CopyState.PartGet
type TickCold = CopyState.TickCold
type State = Composed.State
type StoreKey = Names.StoreKey
type Fields = Value.Fields

local PartMissesForTaker = Extras.PartMissesForTaker

local SubscribersServed: CopyState.Serving = table.freeze({ Kind = "Subscribers" :: "Subscribers" })

local function SendPart(State: State, Purpose: PartGet, Clock: number, Commands: { Command })
	local Follower = Purpose.Follower
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return Tick.EndAfter(State, Follower, Follower.TickEvery, Clock, Commands)
	end
	local HeaderKey = Items.HeaderKey(State.Server.Encoding, Follower.Key, Purpose.Replica)
	Tick.SendGet(State, HeaderKey, Items.PartKey(HeaderKey, Purpose.Header.Q, #Purpose.Got), Purpose, Commands)
end

local function FallBack(State: State, Follower: Follower, Clock: number, Commands: { Command })
	if Follower.Serves.Kind == "Call" then
		if Closing.IsPastDeadline(State.Sessions, Clock) then
			return Tick.EndAfter(State, Follower, Follower.TickEvery, Clock, Commands)
		end
		return Tick.SendHeaderGet(State, Follower, 0, Commands)
	end
	Tick.SendNextToZero(Follower)
	Tick.EndMoved(State, Follower, Clock, Commands)
end

local function Miss(State: State, Follower: Follower, Replica: number, Clock: number, Commands: { Command })
	if Replica ~= 0 then
		return FallBack(State, Follower, Clock, Commands)
	end
	Follower.Misses += 1
	if Follower.Misses >= PartMissesForTaker then
		Follower.Misses = 0
		CopyRefresh.Start(State, Follower.Key, Clock, Commands)
	end
	Tick.EndMoved(State, Follower, Clock, Commands)
end

local function ShowCopied(
	State: State,
	Follower: Follower,
	Header: CopyHeader,
	Copied: Fields,
	Clock: number,
	Commands: { Command }
)
	local Server = State.Server
	local Key = Follower.Key
	local Setup = Cache.StoreOf(Server, Key).Setup
	local Viewed = View.MigrateFrom(Setup, Copied, Header.Level, Header.Floor)
	if Viewed.Kind ~= "State" then
		return Tick.EndQuiet(State, Follower, Clock, Commands)
	end
	if not Shown.IsCopyShown(Server, Key, Header.Q) then
		return KeyPath.StartKeyRead(State, Follower, Clock, Commands)
	end
	Shown.ShowCopy(Server, Key, Header.Q, Header.Incarnation, Clock, State.Sessions.Open)
	local Entry = Numbers.EntryFor(Server, Key)
	Beside.KeepCopyShowable(Server, Entry, Setup, Key, Header.Q, Viewed.State, Composed.ServedOf(State))
	Follower.Misses = 0
	Tick.EmitRising(State, Follower, Header.Q, Viewed.State, Clock, Commands)
end

local function SendCold(State: State, Follower: Follower, Clock: number, Commands: { Command })
	if Closing.IsPastDeadline(State.Sessions, Clock) then
		return Tick.EndAfter(State, Follower, Follower.TickEvery, Clock, Commands)
	end
	local ColdKey = Replicas.ColdKeyOf(State.Server, Follower.Key)
	local Purpose: TickCold = { Kind = "TickCold", Follower = Follower }
	Tick.SendGet(State, ColdKey, ColdKey, Purpose, Commands)
end

local function NoHeader(State: State, Follower: Follower, Clock: number, Commands: { Command })
	CopyRefresh.Start(State, Follower.Key, Clock, Commands)
	Tick.EndQuiet(State, Follower, Clock, Commands)
end

local function IsOwnLeaseUnheld(State: State, Header: CopyHeader, Key: StoreKey): boolean
	local HolderNumber = Header.HolderStamp.HolderNumber
	return HolderNumber == State.Server.ServerNumber and State.Extras.CopyHolders[Names.KeyText(Key)] == nil
end

local function JudgeHeader(
	State: State,
	Follower: Follower,
	Header: CopyHeader,
	Replica: number,
	Fraction: number,
	Clock: number,
	Commands: { Command }
)
	local Server = State.Server
	local Key = Follower.Key
	if Replica == 0 and (Summary.IsLapsed(Header, Clock, Fraction) or IsOwnLeaseUnheld(State, Header, Key)) then
		CopyRefresh.Start(State, Key, Clock, Commands)
	end
	if not Shown.IsCopyAboveShown(Server, Key, Header.Q) then
		return Tick.EndUnchanged(State, Follower, Clock, Commands)
	end
	local Setup = Cache.StoreOf(Server, Key).Setup
	if View.IsFloorBehind(Setup, Header.Floor) then
		Numbers.HearBehind(Server, Key)
		Tick.Deliver(State, Follower, Reads.BehindAnswer, Commands)
		return Tick.EndQuiet(State, Follower, Clock, Commands)
	end
	if Shown.IsAbsentWithBit(Server, Key) then
		return KeyPath.StartKeyRead(State, Follower, Clock, Commands)
	end
	local Body = Header.Body
	if Body.Kind == "State" then
		return ShowCopied(State, Follower, Header, Body.State, Clock, Commands)
	end
	if Body.Kind == "Parts" then
		local Purpose: PartGet = {
			Kind = "PartGet",
			Follower = Follower,
			Header = Header,
			Count = Body.Count,
			Got = {},
			Replica = Replica,
		}
		return SendPart(State, Purpose, Clock, Commands)
	end
	if Body.Kind == "Big" then
		return KeyPath.StartKeyRead(State, Follower, Clock, Commands)
	end
end

local function OnHeader(
	State: State,
	Purpose: HeaderGet,
	_RequestId: number,
	Fetched: MemoryFetched,
	Fraction: number,
	Clock: number,
	Commands: { Command }
)
	local Follower = Purpose.Follower
	if not Tick.IsLive(State, Follower) then
		return
	end
	if Fetched.Kind == "Failed" then
		return SendCold(State, Follower, Clock, Commands)
	end
	local Decoded = if Fetched.Kind == "Found" then Items.DecodeHeader(Fetched.Value) else nil
	if Decoded ~= nil and Decoded.Kind == "Behind" then
		return KeyPath.StartKeyRead(State, Follower, Clock, Commands)
	end
	local Header = if Decoded ~= nil and Decoded.Kind == "Header" then Decoded.Header else nil
	local Replica = Purpose.Replica
	if Replica ~= 0 and (Header == nil or Replicas.IsUnrefreshed(Header, Clock)) then
		return FallBack(State, Follower, Clock, Commands)
	end
	if Header == nil then
		return NoHeader(State, Follower, Clock, Commands)
	end
	Replicas.NoteCount(State.Server, Follower.Key, Header.Replicas)
	JudgeHeader(State, Follower, Header, Replica, Fraction, Clock, Commands)
end

local function SendDecode(State: State, Purpose: PartGet, Commands: { Command })
	local Decoding: Decode =
		{ Kind = "Decode", Follower = Purpose.Follower, Header = Purpose.Header, Replica = Purpose.Replica }
	local Ask: Command = {
		Kind = "Decode",
		RequestId = ExtrasState.NewRequest(State.Server, State.Extras, Decoding),
		Text = Items.JoinPieces(Purpose.Got),
	}
	table.insert(Commands, Ask)
end

local function OnPart(
	State: State,
	Purpose: PartGet,
	_RequestId: number,
	Fetched: MemoryFetched,
	_Fraction: number,
	Clock: number,
	Commands: { Command }
)
	local Follower = Purpose.Follower
	if not Tick.IsLive(State, Follower) then
		return
	end
	if Fetched.Kind == "Failed" then
		return SendCold(State, Follower, Clock, Commands)
	end
	local Header = Purpose.Header
	local Part: CopyPart? = nil
	if Fetched.Kind == "Found" then
		Part = Items.DecodePart(Fetched.Value)
	end
	if Part == nil or Part.Q ~= Header.Q or Part.Level ~= Header.Level then
		return Miss(State, Follower, Purpose.Replica, Clock, Commands)
	end
	table.insert(Purpose.Got, Part)
	if #Purpose.Got < Purpose.Count then
		return SendPart(State, Purpose, Clock, Commands)
	end
	SendDecode(State, Purpose, Commands)
end

local function OnDecoded(State: State, Purpose: Decode, Outcome: DecodeOutcome, Clock: number, Commands: { Command })
	local Follower = Purpose.Follower
	if not Tick.IsLive(State, Follower) then
		return
	end
	if Outcome.Kind ~= "Found" or type(Outcome.Value) ~= "table" then
		return Miss(State, Follower, Purpose.Replica, Clock, Commands)
	end
	ShowCopied(State, Follower, Purpose.Header, Outcome.Value :: Fields, Clock, Commands)
end

local function OnTickCold(
	State: State,
	Purpose: TickCold,
	_RequestId: number,
	Fetched: MemoryFetched,
	_Fraction: number,
	Clock: number,
	Commands: { Command }
)
	local Follower = Purpose.Follower
	if not Tick.IsLive(State, Follower) then
		return
	end
	if Fetched.Kind == "Failed" then
		return KeyPath.StartKeyRead(State, Follower, Clock, Commands)
	end
	Tick.EndQuiet(State, Follower, Clock, Commands)
end

local function IsTickDue(State: State, Follower: Follower, Clock: number): boolean
	local At = Follower.NextAt
	return At ~= nil and Clock >= At and State.Sessions.Shutdown == nil
end

local function OnFollow(State: State, Call: FollowCall, _Arrived: number, Clock: number, Commands: { Command })
	local Followers = State.Extras.Followers
	local Text = Names.KeyText(Call.Key)
	if Followers[Text] == nil then
		local Made = CopyState.NewFollower(Call.Key, SubscribersServed)
		Followers[Text] = Made
		Showables.Serve(State.Server, Call.Key)
		Tick.Begin(State, Made, Clock, Commands)
	end
	Replies.Reply(Commands, Call.CallId, Replies.DoneAnswer)
end

local function OnUnfollow(State: State, Call: UnfollowCall, _Arrived: number, _Clock: number, Commands: { Command })
	State.Extras.Followers[Names.KeyText(Call.Key)] = nil
	Showables.Unserve(State.Server, Call.Key, Composed.ServedOf(State))
	Replies.Reply(Commands, Call.CallId, Replies.DoneAnswer)
end

return {
	OnFollow = OnFollow,
	OnUnfollow = OnUnfollow,
	IsTickDue = IsTickDue,
	OnHeader = OnHeader,
	OnPart = OnPart,
	OnDecoded = OnDecoded,
	OnTickCold = OnTickCold,
}
