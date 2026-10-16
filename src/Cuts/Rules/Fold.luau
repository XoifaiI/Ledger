--!strict
--!optimize 2

--[=[
	Fold: keeps the loss rooms within LossRooms (cuts sheet 7, amend C14). The oldest events fold into at most
	two slots of whole periods, then the oldest named returns go.

	A reset's event gives Wait, and writes nothing, when nothing can make room. An event that cannot fold waits
	until the prune removes it, at its w plus KeepNamed.

	Return type: A plain table with Fold, IsOver, FitLosses and FitReturns, and the FoldResult type.
	Example usage:
		local Result = Fold.Fold(Working, Event, Clock, Setup, "Game")
		Fold.FitLosses(Working, Clock, Setup, "Game")
		Fold.FitReturns(Working, Setup, "Game")
--]=]

local Amounts = require("../../Encoding/Amounts")
local Balances = require("../../Tx/Legs/Balances")
local Book = require("../../Stored/Book")
local Losses = require("../../Stored/Items/Losses")
local Record = require("../../Constants/Record")
local Rooms = require("../../Stored/Rooms")
local Shapes = require("../../Shapes")
local Wide = require("../../Encoding/Wide")

type Book = Book.Book
type SignedAmount = Amounts.SignedAmount
type Event = Losses.Event
type FieldAmount = Losses.FieldAmount
type FoldSlot = Losses.FoldSlot
type Build = Shapes.Build
type Limits = Shapes.Limits
type Setup = Shapes.Setup

export type FoldResult = { read Kind: "Fits" } | { read Kind: "Wait", read At: number }

type Refusals = { Ahead: boolean, ThirdSlot: boolean, Unfoldable: boolean }

local EventRoom = Book.Rooms.Events
local ReturnRoom = Book.Rooms.Returns
local SlotRoom = Book.Rooms.Slots

local RoomUse = Rooms.RoomUse
local SlotEnd = Rooms.SlotEnd
local EpochOf = Rooms.EpochOf

local SignedValueOf = Balances.SignedValueOf
local SignedStoredOf = Balances.SignedStoredOf
local IsStorableAmount = Balances.IsStorableAmount
local AddWide = Wide.AddWide
local IsWithinSignedLimit = Wide.IsWithinSignedLimit

local SlotCountMost = Record.VarintLimit - 1

local Fits: FoldResult = table.freeze({ Kind = "Fits" :: "Fits" })

local function PeriodOf(Stamp: number, Limits: Limits): number
	return Stamp // Limits.FoldSpan
end

local function LossBytes(Working: Book, Limits: Limits): number
	local Epoch = EpochOf(Working) or 0
	return RoomUse(Working.Losses.Events, EventRoom, Epoch, Limits)
		+ RoomUse(Working.Losses.Returns, ReturnRoom, Epoch, Limits)
		+ RoomUse(Working.Slots, SlotRoom, Epoch, Limits)
end

local function IsOver(Working: Book, Limits: Limits, Kind: string): boolean
	return LossBytes(Working, Limits) > Limits.LossRooms[Kind]
end

local function FindSlot(Slots: { FoldSlot }, Period: number): FoldSlot?
	for _, Slot in Slots do
		if Slot.Period == Period then
			return Slot
		end
	end
	return nil
end

local function IndexOfField(Sums: { FieldAmount }, Field: string): number?
	for Index, Sum in Sums do
		if Sum.Field == Field then
			return Index
		end
	end
	return nil
end

local function AddAmount(Sum: SignedAmount?, Entry: FieldAmount, Build: Build): SignedAmount?
	local Amount = Entry.Amount
	if Amount.Kind == "Default" then
		if Sum == nil then
			return Amount
		end
		if Sum.Kind ~= "Default" then
			return nil
		end
		local Total = AddWide(Sum, Amount)
		if not IsWithinSignedLimit(Total) then
			return nil
		end
		return { Kind = "Default", IsNegative = Total.IsNegative, High = Total.High, Low = Total.Low }
	end
	local Arithmetic = Build.Balances[Entry.Field]
	if Arithmetic == nil then
		return nil
	end
	local Held = Arithmetic.Zero
	if Sum ~= nil then
		local Read = SignedValueOf(Sum, Arithmetic)
		if Read == nil then
			return nil
		end
		Held = Read
	end
	local Added = SignedValueOf(Amount, Arithmetic)
	if Added == nil then
		return nil
	end
	local Total = SignedStoredOf(Arithmetic.Add(Held, Added), Arithmetic)
	if not IsStorableAmount(Total) then
		return nil
	end
	return Total
end

local function SumsAfter(Sums: { FieldAmount }, Fields: { FieldAmount }, Build: Build): { FieldAmount }?
	local After = table.clone(Sums)
	for _, Entry in Fields do
		local Index = IndexOfField(After, Entry.Field)
		local Held = if Index == nil then nil else After[Index].Amount
		local Total = AddAmount(Held, Entry, Build)
		if Total == nil then
			return nil
		end
		local Sum: FieldAmount = { Field = Entry.Field, Amount = Total }
		if Index == nil then
			table.insert(After, Sum)
		else
			After[Index] = Sum
		end
	end
	return After
end

local function RemoveEvent(Events: { Event }, Event: Event)
	local Index = table.find(Events, Event)
	if Index == nil then
		return
	end
	table.remove(Events, Index)
end

local function FoldOrDrop(Working: Book, Event: Event, Clock: number, Setup: Setup): Refusals?
	local Limits = Setup.Limits
	local Period = PeriodOf(Event.Stamp, Limits)
	if Clock >= SlotEnd(Period, Limits) then
		RemoveEvent(Working.Losses.Events, Event)
		return nil
	end
	local Standing = FindSlot(Working.Slots, Period)
	local Slot: FoldSlot = Standing or { Period = Period, Count = 0, Sums = {} }
	local Sums = SumsAfter(Slot.Sums, Event.Fields, Setup.Build)
	local IsSlotFull = Slot.Count >= SlotCountMost
	local Refused: Refusals = {
		Ahead = Event.Stamp > Clock,
		ThirdSlot = Standing == nil and #Working.Slots >= Limits.FoldSlotsMost,
		Unfoldable = Sums == nil or IsSlotFull,
	}
	if Sums == nil or IsSlotFull or Refused.Ahead or Refused.ThirdSlot then
		return Refused
	end
	Slot.Sums = Sums
	Slot.Count += 1
	if Standing == nil then
		table.insert(Working.Slots, Slot)
	end
	RemoveEvent(Working.Losses.Events, Event)
	return nil
end

local function FoldOrder(Events: { Event }): { Event }
	local Order = table.clone(Events)
	table.sort(Order, EventRoom.Before)
	return Order
end

local function DropReturns(Working: Book, Limits: Limits, Kind: string)
	local Returns = Working.Losses.Returns
	table.sort(Returns, ReturnRoom.Before)
	while #Returns > 0 and IsOver(Working, Limits, Kind) do
		table.remove(Returns, 1)
	end
end

local function MakeRoom(
	Working: Book,
	Order: { Event },
	Clock: number,
	Setup: Setup,
	Kind: string
): { [Event]: Refusals }
	local Skipped: { [Event]: Refusals } = {}
	for _, Event in Order do
		if not IsOver(Working, Setup.Limits, Kind) then
			break
		end
		local Refused = FoldOrDrop(Working, Event, Clock, Setup)
		if Refused ~= nil then
			Skipped[Event] = Refused
		end
	end
	DropReturns(Working, Setup.Limits, Kind)
	return Skipped
end

local function WaitClock(Skipped: { [Event]: Refusals }, Working: Book, Limits: Limits): number?
	local Candidates: { number } = {}
	local IsThirdSlotWanted = false
	for Event, Refused in Skipped do
		if Refused.Ahead then
			table.insert(Candidates, Event.Stamp)
		end
		if Refused.Unfoldable then
			table.insert(Candidates, Event.Stamp + Limits.KeepNamed)
		end
		if Refused.ThirdSlot then
			IsThirdSlotWanted = true
		end
	end
	if IsThirdSlotWanted then
		for _, Slot in Working.Slots do
			table.insert(Candidates, SlotEnd(Slot.Period, Limits))
		end
	end
	if #Candidates == 0 then
		return nil
	end
	return math.min(table.unpack(Candidates))
end

local function PruneLossRooms(Working: Book, Clock: number, Limits: Limits)
	Rooms.PruneLosses(Working.Losses, Clock, Limits)
	Rooms.PruneSlots(Working.Slots, Clock, Limits)
end

local function TrialOf(Working: Book): Book
	local Trial = table.clone(Working)
	Trial.Losses = { Events = table.clone(Working.Losses.Events), Returns = table.clone(Working.Losses.Returns) }
	Trial.Slots = {}
	for _, Slot in Working.Slots do
		table.insert(Trial.Slots, table.clone(Slot))
	end
	return Trial
end

local function Fold(Working: Book, New: Event, Clock: number, Setup: Setup, Kind: string): FoldResult
	local Limits = Setup.Limits
	PruneLossRooms(Working, Clock, Limits)
	local Trial = TrialOf(Working)
	local Order = FoldOrder(Trial.Losses.Events)
	table.insert(Order, New)
	table.insert(Trial.Losses.Events, New)
	local Skipped = MakeRoom(Trial, Order, Clock, Setup, Kind)
	if IsOver(Trial, Limits, Kind) then
		local At = WaitClock(Skipped, Trial, Limits)
		if At ~= nil then
			return { Kind = "Wait", At = At }
		end
	end
	Working.Losses = Trial.Losses
	Working.Slots = Trial.Slots
	return Fits
end

local function FitReturns(Working: Book, Setup: Setup, Kind: string)
	DropReturns(Working, Setup.Limits, Kind)
end

local function FitLosses(Working: Book, Clock: number, Setup: Setup, Kind: string)
	PruneLossRooms(Working, Clock, Setup.Limits)
	MakeRoom(Working, FoldOrder(Working.Losses.Events), Clock, Setup, Kind)
end

return {
	Fold = Fold,
	IsOver = IsOver,
	FitLosses = FitLosses,
	FitReturns = FitReturns,
}
