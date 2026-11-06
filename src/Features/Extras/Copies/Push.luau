--!strict
--!optimize 2

--[=[
	Push: what a copy holder writes (extras sheet E8, cuts sheet 8.6): a push's plan, and each replica's parts and
	header. A push writes every replica other than 0 at once, parts before header, and replica 0 once all of them
	answered; if any failed, replica 0 is written as a push to replica 0 alone, so its Written stays below Replicas.
	A header's update with a smaller q than its replica holds is cancelled (extras 5.2); else it merges into it
	(Replicas.Merge), and on replica 0 a lease of another server that has not run out refuses it. On an equal q a
	push at another level writes its level, floor and body; a renew writes replica 0 alone and keeps the held ones.
	A plan measures its header at the largest count.

	Return type: A plain table of functions.
	Example usage:
		CopyPush.Start(State, Holder, CopyPush.NewPlan(State, Opened, Clock), Count, Clock, Commands)
--]=]

local Cache = require("../../../Record/Reading/Cache")
local Composed = require("../../../Machine/Composed")
local CopyState = require("./State")
local Events = require("../../../Machine/Events")
local Extras = require("../../../Record/Constants/Extras")
local ExtrasShapes = require("../Shapes")
local ExtrasState = require("../State")
local Items = require("./Items")
local Json = require("../../../Record/Encoding/Json")
local Numbers = require("../../../Record/Writing/Numbers")
local Reads = require("../../../Record/Reading/Reads")
local Replicas = require("./Replicas")
local Shapes = require("../../../Machine/Shapes")
local View = require("../../../Record/Reading/View")

type Command = Events.Command
type CopyHolder = CopyState.CopyHolder
type CopyLease = CopyState.CopyLease
type CopyPlan = CopyState.CopyPlan
type CopyPush = CopyState.CopyPush
type HeaderUpdate = CopyState.HeaderUpdate
type PartSet = CopyState.PartSet
type CopyBody = ExtrasShapes.CopyBody
type CopyHeader = ExtrasShapes.CopyHeader
type HolderStamp = ExtrasShapes.HolderStamp
type Opened = Reads.Opened
type ServerState = Shapes.ServerState
type State = Composed.State

local CopyExpiry = Extras.CopyExpiry
local ReplicasMost = Extras.ReplicasMost
local HolderSpan = Extras.HolderSpan

local HeaderWrite = {
	Push = "Push" :: "Push",
	Renew = "Renew" :: "Renew",
}

type HeaderWrite = keyof<typeof(HeaderWrite)>

local function TakesCarriedLevel(Write: HeaderWrite, Held: CopyHeader, Carried: CopyHeader): boolean
	return Write == HeaderWrite.Push and Carried.Level ~= Held.Level
end

local function IsHeldByAnother(Held: CopyHeader, Carried: CopyHeader, Clock: number): boolean
	return Held.HolderStamp.HolderNumber ~= Carried.HolderStamp.HolderNumber and Held.HolderStamp.Until > Clock
end

local function HeaderTransform(
	Carried: CopyHeader,
	Write: HeaderWrite,
	Replica: number
): (Current: unknown, Clock: number) -> unknown?
	return function(Current: unknown, Clock: number): unknown?
		local Decoded = Items.DecodeHeader(Current)
		if Decoded.Kind == "Behind" then
			return nil
		end
		if Decoded.Kind ~= "Header" then
			return Items.EncodeHeader(Carried)
		end
		local Held = Decoded.Header
		if Carried.Q < Held.Q or (Replica == 0 and IsHeldByAnother(Held, Carried, Clock)) then
			return nil
		end
		return Items.EncodeHeader(Replicas.Merge(Held, Carried, TakesCarriedLevel(Write, Held, Carried)))
	end
end

local function NewHolderStamp(Server: ServerState, Clock: number): HolderStamp
	return { HolderNumber = Numbers.ServerNumberOf(Server), Until = Clock + HolderSpan, At = Clock }
end

local function HeaderOf(Plan: CopyPlan, Stamped: HolderStamp, Count: number, Written: number): CopyHeader
	return {
		Q = Plan.Q,
		Level = Plan.Level,
		Floor = Plan.Floor,
		Incarnation = Plan.Incarnation,
		HolderStamp = Stamped,
		Body = Plan.Body,
		Replicas = Count,
		Written = Written,
	}
end

local function PlanWith(Whole: CopyPlan, Body: CopyBody, Pieces: { string }): CopyPlan
	return {
		Q = Whole.Q,
		Level = Whole.Level,
		Floor = Whole.Floor,
		Incarnation = Whole.Incarnation,
		Body = Body,
		Pieces = Pieces,
	}
end

local function NewPlan(State: State, Opened: Opened, Clock: number): CopyPlan
	local Server = State.Server
	local Book = Opened.Kept.Book
	local Build = Cache.StoreOf(Server, Opened.Out.Key).Setup.Build
	local Level = math.max(Book.Level, Build.MigrationCount)
	local Whole: CopyPlan = {
		Q = Book.Writes,
		Level = Level,
		Floor = View.MigratedFloor(Build, Book.Level, Book.Floor),
		Incarnation = Book.Identity or false,
		Body = { Kind = "State", State = Opened.Viewed },
		Pieces = {},
	}
	if Items.Fits(HeaderOf(Whole, NewHolderStamp(Server, Clock), ReplicasMost, ReplicasMost)) then
		return Whole
	end
	local Pieces = Items.CutPieces(Json.CanonicalJson(Opened.Viewed), Whole.Q, Level)
	if Pieces == nil then
		return PlanWith(Whole, { Kind = "Big" }, {})
	end
	return PlanWith(Whole, { Kind = "Parts", Count = #Pieces }, Pieces)
end

local function SendHeaderUpdate(State: State, Purpose: HeaderUpdate, Write: HeaderWrite, Commands: { Command })
	local Encoding = State.Server.Encoding
	local Key = Items.HeaderKey(Encoding, Purpose.Holder.Key, Purpose.Replica)
	local Update: Command = {
		Kind = "MemoryUpdate",
		RequestId = ExtrasState.NewRequest(State.Server, State.Extras, Purpose),
		Map = Items.CopyMap(Encoding, Key),
		Key = Key,
		Item = HeaderTransform(Purpose.Header, Write, Purpose.Replica),
		Expiry = CopyExpiry,
	}
	table.insert(Commands, Update)
end

local function CountOf(Push: CopyPush, Replica: number): number
	if Replica ~= 0 or Push.IsWhole then
		return Push.Count
	end
	return 1
end

local function SendPushHeader(
	State: State,
	Holder: CopyHolder,
	Push: CopyPush,
	Replica: number,
	Clock: number,
	Commands: { Command }
)
	local Count = CountOf(Push, Replica)
	local Purpose: HeaderUpdate = {
		Kind = "HeaderUpdate",
		Holder = Holder,
		Header = HeaderOf(Push.Plan, NewHolderStamp(State.Server, Clock), Count, Count),
		PushedAt = Clock,
		Replica = Replica,
		Push = Push,
	}
	SendHeaderUpdate(State, Purpose, HeaderWrite.Push, Commands)
end

local function SendRenewHeader(
	State: State,
	Holder: CopyHolder,
	Plan: CopyPlan,
	Lease: CopyLease,
	Clock: number,
	Commands: { Command }
)
	local Purpose: HeaderUpdate = {
		Kind = "HeaderUpdate",
		Holder = Holder,
		Header = HeaderOf(Plan, NewHolderStamp(State.Server, Clock), Lease.Replicas, Lease.Written),
		PushedAt = Lease.PushedAt,
		Replica = 0,
		Push = nil,
	}
	SendHeaderUpdate(State, Purpose, HeaderWrite.Renew, Commands)
end

local function SendPart(
	State: State,
	Holder: CopyHolder,
	Push: CopyPush,
	Replica: number,
	Index: number,
	Commands: { Command }
)
	local Encoding = State.Server.Encoding
	local HeaderKey = Items.HeaderKey(Encoding, Holder.Key, Replica)
	local Plan = Push.Plan
	local Purpose: PartSet = { Kind = "PartSet", Holder = Holder, Push = Push, Replica = Replica, Index = Index }
	local Set: Command = {
		Kind = "MemorySet",
		RequestId = ExtrasState.NewRequest(State.Server, State.Extras, Purpose),
		Map = Items.CopyMap(Encoding, HeaderKey),
		Key = Items.PartKey(HeaderKey, Plan.Q, Index),
		Item = Items.EncodePart({ Q = Plan.Q, Level = Plan.Level, Piece = Plan.Pieces[Index + 1] }),
		Expiry = CopyExpiry,
	}
	table.insert(Commands, Set)
end

local function SendReplica(
	State: State,
	Holder: CopyHolder,
	Push: CopyPush,
	Replica: number,
	Clock: number,
	Commands: { Command }
)
	if #Push.Plan.Pieces == 0 then
		return SendPushHeader(State, Holder, Push, Replica, Clock, Commands)
	end
	SendPart(State, Holder, Push, Replica, 0, Commands)
end

local function Start(
	State: State,
	Holder: CopyHolder,
	Plan: CopyPlan,
	Count: number,
	Clock: number,
	Commands: { Command }
)
	local Push: CopyPush = { Plan = Plan, Count = Count, Left = Count - 1, IsWhole = true }
	if Push.Left == 0 then
		return SendReplica(State, Holder, Push, 0, Clock, Commands)
	end
	for Replica = 1, Count - 1 do
		SendReplica(State, Holder, Push, Replica, Clock, Commands)
	end
end

return {
	HeaderTransform = HeaderTransform,
	NewPlan = NewPlan,
	Start = Start,
	SendReplica = SendReplica,
	SendPart = SendPart,
	SendPushHeader = SendPushHeader,
	SendRenewHeader = SendRenewHeader,
}
