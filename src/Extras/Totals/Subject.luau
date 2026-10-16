--!strict
--!optimize 2

--[=[
	Subject: what a Total and a summary refresh read: a total's shards (Pairs) or a quantity's parts, the walk's view
	(Keys = "Part", KeyCount parts). It keys, reads, transforms and answers (sheets E4, H9), placing entries by
	Summary's places. A TotalView is keyed without Keys: the API refuses a total and a quantity under one name.

	Return type: A plain table of functions, and the ItemRead type.
	Example usage:
		local Key = Subject.KeyOf({ Store = "Shop", Scope = "global", Total = Total }, 3)
--]=]

local Cache = require("../../Reading/Cache")
local Composed = require("../../Composed")
local Events = require("../../Events")
local ExtrasShapes = require("../Shapes")
local ExtrasState = require("../State")
local HotShapes = require("../../Hot/Shapes")
local HotState = require("../../Hot/State")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Pairs = require("./Pairs")
local PartBuild = require("../../Hot/Part/Build")
local PartRead = require("../../Hot/Walk/Read")
local Record = require("../../Constants/Record")
local Shapes = require("../../Shapes")
local Shard = require("./Shard")
local Summary = require("./Summary")
local Value = require("../../Stored/Value")
local View = require("../../Hot/Walk/View")

type HolderStamp = ExtrasShapes.HolderStamp
type MemoryFetched = Events.MemoryFetched
type ReadOutcome = Events.ReadOutcome
type StoreKey = Names.StoreKey
type Kept = Value.Kept
type Pair = ExtrasShapes.Pair
type QuantityName = HotShapes.QuantityName
type QuantityView = HotState.QuantityView
type RawEntry = Summary.RawEntry
type SummaryItem<Entry> = ExtrasShapes.SummaryItem<Entry>
type TotalDeclaration = ExtrasShapes.TotalDeclaration
type TotalRef = ExtrasShapes.TotalRef
type TotalView = ExtrasState.TotalView
type ViewEntry = HotState.ViewEntry
type ServerState = Shapes.ServerState
type State = Composed.State
type Item<Entry> =
	{ read Kind: "Item", read Item: SummaryItem<Entry> }
	| { read Kind: "Behind" }
	| { read Kind: "Unreadable" }
type Decoded = Item<Pair>
type DecodedParts = Item<ViewEntry>
export type ItemRead =
	{ read Kind: "Item", read HolderStamp: HolderStamp }
	| { read Kind: "Behind" }
	| { read Kind: "Missing" }

local PartKind = Record.KeyKind.Part
local Flags = Summary.Flags
local PairPlaces = Summary.PairPlaces
local PartPlaces = Summary.PartPlaces

local MissingItem: ItemRead = table.freeze({ Kind = "Missing" :: "Missing" })
local BehindItem: ItemRead = table.freeze({ Kind = "Behind" :: "Behind" })
local NoKeyPair: Pair = table.freeze({ Q = 0, Sum = 0 })

local function IsQuantity(Total: TotalDeclaration): boolean
	return Total.Keys == PartKind
end

local function QuantityOf(Ref: TotalRef): QuantityName
	return { Name = Ref.Total.Name, Parts = Ref.Total.KeyCount }
end

local function ViewOf(State: State, Ref: TotalRef): TotalView
	return ExtrasState.ViewOf(State.Extras, Ref.Store, Ref.Scope, Ref.Total)
end

local function PartsOf(State: State, Ref: TotalRef): QuantityView
	return HotState.ViewOf(State.Hot, Ref.Store, Ref.Scope, QuantityOf(Ref))
end

local function KeyOf(Ref: TotalRef, Index: number): StoreKey
	if IsQuantity(Ref.Total) then
		return PartBuild.PartKey(Ref.Store, Ref.Scope, QuantityOf(Ref), Index)
	end
	return Shard.ShardKey(Ref.Store, Ref.Scope, Ref.Total, Index)
end

local function MissingIndexes(State: State, Ref: TotalRef): { number }
	if IsQuantity(Ref.Total) then
		return View.Lacking(PartsOf(State, Ref), Ref.Total.KeyCount)
	end
	return Pairs.Pairless(ViewOf(State, Ref), Ref.Total.KeyCount)
end

local function IsComplete(State: State, Ref: TotalRef): boolean
	return #MissingIndexes(State, Ref) == 0
end

local function Answer(State: State, Ref: TotalRef): unknown
	if IsQuantity(Ref.Total) then
		return View.QuantityOf(PartsOf(State, Ref), Ref.Total.KeyCount)
	end
	return Pairs.SumOf(ViewOf(State, Ref), Ref.Total.KeyCount)
end

local function RawOfPair(Given: Pair): RawEntry
	return { [PairPlaces.Q] = Given.Q, [PairPlaces.Sum] = Given.Sum }
end

local function RawOfPart(Given: ViewEntry): RawEntry
	local Sealed = if Given.IsSealed then Flags.Set else Flags.Clear
	local Closed = if Given.IsClosed then Flags.Set else Flags.Clear
	return {
		[PartPlaces.Q] = Given.Q,
		[PartPlaces.Free] = Given.Free,
		[PartPlaces.Held] = Given.Held,
		[PartPlaces.Sold] = Given.Sold,
		[PartPlaces.Sealed] = Sealed,
		[PartPlaces.Closed] = Closed,
	}
end

local function PairOf(Entry: RawEntry): Pair
	return { Q = Entry[PairPlaces.Q], Sum = Entry[PairPlaces.Sum] }
end

local function PartOf(Entry: RawEntry): ViewEntry
	return {
		Q = Entry[PartPlaces.Q],
		Free = Entry[PartPlaces.Free],
		Held = Entry[PartPlaces.Held],
		Sold = Entry[PartPlaces.Sold],
		IsSealed = Entry[PartPlaces.Sealed] == Flags.Set,
		IsClosed = Entry[PartPlaces.Closed] == Flags.Set,
	}
end

local function DecodeShards(Stored: unknown, Shards: number): Decoded
	local Read = Summary.ReadItem(Stored, Shards, Summary.PairForm)
	if Read.Kind ~= "Item" then
		return Read
	end
	local Entries: { [number]: Pair } = {}
	for Index, Entry in Read.Entries do
		Entries[Index] = PairOf(Entry)
	end
	return { Kind = "Item", Item = { HolderStamp = Read.HolderStamp, Entries = Entries } }
end

local function DecodeParts(Stored: unknown, Parts: number): DecodedParts
	local Read = Summary.ReadItem(Stored, Parts, Summary.PartForm)
	if Read.Kind ~= "Item" then
		return Read
	end
	local Entries: { [number]: ViewEntry } = {}
	for Index, Entry in Read.Entries do
		Entries[Index] = PartOf(Entry)
	end
	return { Kind = "Item", Item = { HolderStamp = Read.HolderStamp, Entries = Entries } }
end

local function ReadParts(State: State, Ref: TotalRef, Stored: unknown): ItemRead
	local Decoded = DecodeParts(Stored, Ref.Total.KeyCount)
	if Decoded.Kind == "Behind" then
		return BehindItem
	end
	if Decoded.Kind ~= "Item" then
		return MissingItem
	end
	local Known = PartsOf(State, Ref)
	for Index, Entry in Decoded.Item.Entries do
		View.Merge(Known, Index, Entry)
	end
	return { Kind = "Item", HolderStamp = Decoded.Item.HolderStamp }
end

local function ReadShards(State: State, Ref: TotalRef, Stored: unknown): ItemRead
	local Decoded = DecodeShards(Stored, Ref.Total.KeyCount)
	if Decoded.Kind == "Behind" then
		return BehindItem
	end
	if Decoded.Kind ~= "Item" then
		return MissingItem
	end
	local Known = ViewOf(State, Ref)
	for Index, Pair in Decoded.Item.Entries do
		Pairs.MergePair(Known, Index, Pair)
	end
	return { Kind = "Item", HolderStamp = Decoded.Item.HolderStamp }
end

local function ReadItem(State: State, Ref: TotalRef, Fetched: MemoryFetched): ItemRead
	if Fetched.Kind ~= "Found" then
		return MissingItem
	end
	if IsQuantity(Ref.Total) then
		return ReadParts(State, Ref, Fetched.Value)
	end
	return ReadShards(State, Ref, Fetched.Value)
end

local function TransformShards(
	Carried: { [number]: Pair },
	Shards: number,
	ServerNumber: number
): (Current: unknown, Clock: number) -> unknown?
	local Raw: { [number]: RawEntry } = {}
	for Index, Given in Carried do
		Raw[Index] = RawOfPair(Given)
	end
	return Summary.TransformRaw(Raw, Shards, ServerNumber, Summary.PairForm)
end

local function TransformParts(
	Carried: { [number]: ViewEntry },
	Parts: number,
	ServerNumber: number
): (Current: unknown, Clock: number) -> unknown?
	local Raw: { [number]: RawEntry } = {}
	for Index, Given in Carried do
		Raw[Index] = RawOfPart(Given)
	end
	return Summary.TransformRaw(Raw, Parts, ServerNumber, Summary.PartForm)
end

local function TransformFor(
	State: State,
	Ref: TotalRef,
	ServerNumber: number
): (Current: unknown, Clock: number) -> unknown?
	local Total = Ref.Total
	if IsQuantity(Total) then
		return TransformParts(table.clone(PartsOf(State, Ref).Parts), Total.KeyCount, ServerNumber)
	end
	return TransformShards(table.clone(ViewOf(State, Ref).Pairs), Total.KeyCount, ServerNumber)
end

local function LearnShardRead(
	Server: ServerState,
	Key: StoreKey,
	Known: TotalView,
	Index: number,
	Fetched: ReadOutcome,
	Clock: number
): Kept?
	if Fetched.Kind == "Failed" then
		return nil
	end
	local Read = Numbers.LearnStored(Server, Key, Cache.StoreOf(Server, Key).Setup, Fetched, Clock)
	if Read.Kind == "Unreadable" then
		return nil
	end
	Known.ReadAt[Index] = Clock
	if Read.Kind == "Nothing" then
		Pairs.MergePair(Known, Index, NoKeyPair)
		return nil
	end
	Pairs.MergePair(Known, Index, Pairs.PairOf(Read.Kept))
	return Read.Kept
end

local function LearnPartRead(State: State, Ref: TotalRef, Index: number, Fetched: ReadOutcome, Clock: number): Kept?
	local Read = PartRead.LearnPart(State, Ref.Store, Ref.Scope, QuantityOf(Ref), Index, Fetched, Clock)
	if Read == nil or Read.Kind == "Unreadable" then
		return nil
	end
	ViewOf(State, Ref).ReadAt[Index] = Clock
	if Read.Kind == "Kept" then
		return Read.Kept
	end
	return nil
end

local function LearnRead(State: State, Ref: TotalRef, Index: number, Fetched: ReadOutcome, Clock: number): Kept?
	if IsQuantity(Ref.Total) then
		return LearnPartRead(State, Ref, Index, Fetched, Clock)
	end
	return LearnShardRead(State.Server, KeyOf(Ref, Index), ViewOf(State, Ref), Index, Fetched, Clock)
end

return {
	KeyOf = KeyOf,
	ViewOf = ViewOf,
	MissingIndexes = MissingIndexes,
	IsComplete = IsComplete,
	Answer = Answer,
	ReadItem = ReadItem,
	TransformFor = TransformFor,
	LearnRead = LearnRead,
}
