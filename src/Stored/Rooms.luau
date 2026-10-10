--!strict
--!optimize 2

--[=[
	Rooms: the age and fit steps of a write (record sheet 9, S.7 and S.8, with the cuts sheet's), the measure of a
	room, and CountItems, the items a book holds.

	Age, the prunes and the fits work in place and raise Horizon or CutHorizon. Limits.ItemSize is the item's
	encoded bytes at Limits.WindowUnit in production and 1 in a replay.

	Return type: A plain table of functions.
	Example usage:
		local GateDropped = Rooms.Age(Working, Clock, OwnWriterId, Limits)
		Rooms.FitTimed(Working, Clock, Written, Epoch, Kind, Limits)
		Rooms.FitCutNames(Working, Limits)
		local Epoch = Rooms.EpochOf(Working)
		local Count = Rooms.CountItems(Working)
		Rooms.SortRooms(Working)
		local End = Rooms.SlotEnd(Period, Limits)
--]=]

local Book = require("./Book")
local Losses = require("./Items/Losses")
local Shapes = require("../Shapes")
local Timed = require("./Items/Timed")

type Book = Book.Book
type Room<Item> = Book.Room<Item>
type Limits = Shapes.Limits
type TimedItem = Timed.TimedItem
type CutName = Timed.CutName
type LossItems = Losses.LossItems
type FoldSlot = Losses.FoldSlot

local TimedRoom = Book.Rooms.Timed
local CutNameRoom = Book.Rooms.CutNames
local UntimedRoom = Book.Rooms.Untimed
local WorkItemRoom = Book.Rooms.Work
local SlotRoom = Book.Rooms.Slots

local FreeTier = 1
local WrittenTier = 2
local AheadTier = 3

local function ItemStamp(Item: TimedItem): number
	if Item.Kind == "Writer" then
		return Item.Newest
	end
	return Item.Stamp
end

local function RoomUse<Item>(Items: { Item }, Room: Room<Item>, Epoch: number, Limits: Limits): number
	local Used = 0
	for _, Item in Items do
		Used += Limits.ItemSize(Room, Item, Epoch, Limits.WindowUnit)
	end
	return Used
end

local function UntimedRoomLeft(Working: Book, Epoch: number, Kind: string, Limits: Limits): number
	return Limits.UntimedRooms[Kind] - RoomUse(Working.Untimed, UntimedRoom, Epoch, Limits)
end

local function IsWindowAged(Clock: number, Stamp: number, Window: number): boolean
	return Clock - Stamp >= Window
end

local function IsKeepNamedAged(Clock: number, Stamp: number, Limits: Limits): boolean
	return IsWindowAged(Clock, Stamp, Limits.KeepNamed)
end

local function SlotEnd(Period: number, Limits: Limits): number
	return (Period + Limits.SlotSpans) * Limits.FoldSpan
end

local function IsSlotExpired(Clock: number, Slot: FoldSlot, Limits: Limits): boolean
	return Clock >= SlotEnd(Slot.Period, Limits)
end

local function IsTimedAged(Item: TimedItem, Clock: number, OwnWriterId: number?, Limits: Limits): boolean
	if Item.Kind == "Named" then
		return IsWindowAged(Clock, Item.Stamp, Item.WindowSeconds)
	end
	if Item.WriterId == OwnWriterId then
		return false
	end
	return IsWindowAged(Clock, Item.Newest, Limits.MintedWindow)
end

local function AgeTimed(Working: Book, Clock: number, OwnWriterId: number?, Limits: Limits)
	local Items = Working.Timed
	for Index = #Items, 1, -1 do
		local Item = Items[Index]
		if IsTimedAged(Item, Clock, OwnWriterId, Limits) then
			Working.Horizon = math.max(Working.Horizon, ItemStamp(Item))
			table.remove(Items, Index)
		end
	end
end

local function AgeCutNames(Working: Book, Clock: number)
	local Items = Working.CutNames
	for Index = #Items, 1, -1 do
		local Item = Items[Index]
		if IsWindowAged(Clock, Item.Stamp, Item.WindowSeconds) then
			Working.CutHorizon = math.max(Working.CutHorizon, Item.Stamp)
			table.remove(Items, Index)
		end
	end
end

local function AgeUntimed(Working: Book, Clock: number)
	local Items = Working.Untimed
	for Index = #Items, 1, -1 do
		local Item = Items[Index]
		if IsWindowAged(Clock, Item.Stamp, Item.WindowSeconds) then
			table.remove(Items, Index)
		end
	end
end

local function AgeGate(Working: Book, Clock: number, Limits: Limits): boolean
	local Gate = Working.Gate
	if Gate == nil then
		return false
	end
	if not IsWindowAged(Clock, Gate.Stamp, Limits.CutWindow) then
		return false
	end
	Working.CutHorizon = math.max(Working.CutHorizon, Gate.Stamp)
	Working.Gate = nil
	return true
end

local function PruneLosses(LossRoom: LossItems, Clock: number, Limits: Limits)
	local Events = LossRoom.Events
	for Index = #Events, 1, -1 do
		if IsKeepNamedAged(Clock, Events[Index].Stamp, Limits) then
			table.remove(Events, Index)
		end
	end
	local Returns = LossRoom.Returns
	for Index = #Returns, 1, -1 do
		if IsKeepNamedAged(Clock, Returns[Index].Stamp, Limits) then
			table.remove(Returns, Index)
		end
	end
end

local function PruneSlots(Slots: { FoldSlot }, Clock: number, Limits: Limits)
	for Index = #Slots, 1, -1 do
		if IsSlotExpired(Clock, Slots[Index], Limits) then
			table.remove(Slots, Index)
		end
	end
end

local function Age(Working: Book, Clock: number, OwnWriterId: number?, Limits: Limits): boolean
	AgeTimed(Working, Clock, OwnWriterId, Limits)
	AgeCutNames(Working, Clock)
	AgeUntimed(Working, Clock)
	local IsGateDropped = AgeGate(Working, Clock, Limits)
	PruneLosses(Working.Losses, Clock, Limits)
	PruneSlots(Working.Slots, Clock, Limits)
	return IsGateDropped
end

local function TierOf(Item: TimedItem, Clock: number, Written: { [TimedItem]: boolean }, Limits: Limits): number
	if ItemStamp(Item) > Clock + Limits.Hold then
		return AheadTier
	end
	if Written[Item] then
		return WrittenTier
	end
	return FreeTier
end

local function DropsBefore(
	Item: TimedItem,
	Least: TimedItem,
	Clock: number,
	Written: { [TimedItem]: boolean },
	Limits: Limits
): boolean
	local ItemTier = TierOf(Item, Clock, Written, Limits)
	local LeastTier = TierOf(Least, Clock, Written, Limits)
	if ItemTier ~= LeastTier then
		return ItemTier < LeastTier
	end
	local ItemStampValue = ItemStamp(Item)
	local LeastStamp = ItemStamp(Least)
	if ItemStampValue ~= LeastStamp then
		return ItemStampValue < LeastStamp
	end
	return TimedRoom.Before(Item, Least)
end

local function LeastKept(
	Items: { TimedItem },
	Dropped: { [TimedItem]: boolean },
	Clock: number,
	Written: { [TimedItem]: boolean },
	Limits: Limits
): TimedItem?
	local Least: TimedItem? = nil
	for _, Item in Items do
		if Dropped[Item] then
			continue
		end
		if Least == nil or DropsBefore(Item, Least, Clock, Written, Limits) then
			Least = Item
		end
	end
	return Least
end

local function FitTimed(
	Working: Book,
	Clock: number,
	Written: { [TimedItem]: boolean },
	Epoch: number,
	Kind: string,
	Limits: Limits
)
	local RoomSize = Limits.TimedRooms[Kind]
	local Used = RoomUse(Working.Timed, TimedRoom, Epoch, Limits)
	if Used <= RoomSize then
		return
	end
	local Dropped: { [TimedItem]: boolean } = {}
	local Horizon = Working.Horizon
	while Used > RoomSize do
		local Item = LeastKept(Working.Timed, Dropped, Clock, Written, Limits)
		if Item == nil then
			break
		end
		Dropped[Item] = true
		Used -= Limits.ItemSize(TimedRoom, Item, Epoch, Limits.WindowUnit)
		Horizon = math.max(Horizon, ItemStamp(Item))
	end
	local Kept: { TimedItem } = {}
	for _, Item in Working.Timed do
		if not Dropped[Item] then
			table.insert(Kept, Item)
		end
	end
	Working.Timed = Kept
	Working.Horizon = Horizon
end

local function LeastCutNameIndex(Names: { CutName }): number
	local Least = 1
	for Index, Name in Names do
		if CutNameRoom.Before(Name, Names[Least]) then
			Least = Index
		end
	end
	return Least
end

local function FitCutNames(Working: Book, Limits: Limits)
	while #Working.CutNames > Limits.CutNamesKept do
		local Index = LeastCutNameIndex(Working.CutNames)
		local Dropped = Working.CutNames[Index]
		table.remove(Working.CutNames, Index)
		Working.CutHorizon = math.max(Working.CutHorizon, Dropped.Stamp)
	end
end

local function Earlier(Current: number?, Stamp: number): number
	if Current == nil then
		return Stamp
	end
	return math.min(Current, Stamp)
end

local function EpochOf(Working: Book): number?
	local Least: number? = nil
	for _, Item in Working.Timed do
		Least = Earlier(Least, ItemStamp(Item))
	end
	for _, Item in Working.CutNames do
		Least = Earlier(Least, Item.Stamp)
	end
	for _, Item in Working.Untimed do
		Least = Earlier(Least, Item.Stamp)
	end
	for _, Mark in Working.Work do
		Least = Earlier(Least, Mark.Opening.Stamp)
	end
	for _, Event in Working.Losses.Events do
		Least = Earlier(Least, Event.Stamp)
	end
	for _, Return in Working.Losses.Returns do
		Least = Earlier(Least, Return.Stamp)
	end
	return Least
end

local function CountItems(Working: Book): number
	local Count = #Working.Timed + #Working.CutNames + #Working.Untimed + #Working.Work + #Working.Slots
	Count += Losses.LossCount(Working.Losses)
	if Working.Gate ~= nil then
		Count += 1
	end
	return Count
end

local function SortRooms(Working: Book)
	table.sort(Working.Timed, TimedRoom.Before)
	table.sort(Working.CutNames, CutNameRoom.Before)
	table.sort(Working.Untimed, UntimedRoom.Before)
	table.sort(Working.Work, WorkItemRoom.Before)
	table.sort(Working.Losses.Events, Losses.EventBefore)
	table.sort(Working.Losses.Returns, Losses.ReturnBefore)
	table.sort(Working.Slots, SlotRoom.Before)
end

return {
	ItemStamp = ItemStamp,
	RoomUse = RoomUse,
	UntimedRoomLeft = UntimedRoomLeft,
	SlotEnd = SlotEnd,
	AgeCutNames = AgeCutNames,
	PruneLosses = PruneLosses,
	PruneSlots = PruneSlots,
	Age = Age,
	FitTimed = FitTimed,
	FitCutNames = FitCutNames,
	EpochOf = EpochOf,
	CountItems = CountItems,
	SortRooms = SortRooms,
}
