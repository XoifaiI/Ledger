--!strict
--!optimize 2

--[=[
	View: a quantity's parts as this server knows them (sheet H3, H6, H9). An entry merges by the larger q; sealed
	and closed, once known, stay. NoteNo seals, closes, or notes a refusal apart. The view orders a walk's parts,
	answers SoldOut and Busy from memory, sums parts for Total, and enters a missing part as q 0. AbsentAt keeps when a
	read found a part absent, until a real entry beats it.

	Return type: A plain table of functions.
	Example usage:
		View.Merge(Quantity, 2, View.EntryOfState(Written.Book.Writes, Written.State))
		local Order = View.GameOrder(Server.Encoding, "order-42", 4) --> for example { 3, 0, 1, 2 }
--]=]

local Fates = require("../../Stored/Items/Fates")
local Format = require("../../Encoding/Format")
local HashInputs = require("../../Encoding/HashInputs")
local Holds = require("../Part/Holds")
local Hot = require("../../Constants/Hot")
local HotShapes = require("../Shapes")
local Numbers = require("../../Writing/Numbers")
local Part = require("../../Stored/Items/Part")
local Shapes = require("../../Shapes")
local State = require("../State")
local Value = require("../../Stored/Value")

type Encoding = HashInputs.Encoding
type Writer = Format.Writer
type PartReason = Fates.PartReason
type Fields = Value.Fields
type LandedValue = Shapes.LandedValue
type StoredRead = Numbers.StoredRead
type QuantityDeclaration = HotShapes.QuantityDeclaration
type QuantityTotal = HotShapes.QuantityTotal
type QuantityView = State.QuantityView
type ViewEntry = State.ViewEntry

type FreeAt = {
	Index: number,
	Free: number,
}

local ViewAge = Hot.ViewAge
local PartReasons = Fates.PartReason

local AbsentEntry: ViewEntry = table.freeze({
	Q = 0,
	Free = 0,
	Held = 0,
	Sold = 0,
	IsSealed = false,
	IsClosed = false,
})

local ModuleName = "View"
local QuantityNeedsEveryPart = `{ModuleName}: this call is never made. QuantityOf is given only a view that lacks no`
	.. " part; the caller checks Lacking first"

local function ChoiceOf(Encoding: Encoding, Input: Writer): number
	return HashInputs.ChoiceNumber(HashInputs.Hash(Encoding, Input))
end

local function GameOrder(Encoding: Encoding, Name: string, Parts: number): { number }
	local First = ChoiceOf(Encoding, HashInputs.WalkInput(Name))
	local Order: { number } = {}
	for Step = 0, Parts - 1 do
		table.insert(Order, (First + Step) % Parts)
	end
	return Order
end

local function HomePart(Encoding: Encoding, Quantity: QuantityDeclaration, ServerNumber: number): number
	return ChoiceOf(Encoding, HashInputs.HomePartInput(Quantity.Name, Quantity.Parts, ServerNumber)) % Quantity.Parts
end

local function IsShort(View: QuantityView, Index: number, Count: number, Clock: number): boolean
	local Refused = View.Refusals[Index]
	if Refused == nil then
		return false
	end
	return Refused.Count <= Count and Clock - Refused.At <= ViewAge
end

local function IsSealedOrClosed(View: QuantityView, Index: number): boolean
	local Entry = View.Parts[Index]
	if Entry == nil then
		return false
	end
	return Entry.IsSealed or Entry.IsClosed
end

local function IsPassed(View: QuantityView, Index: number, Count: number, Clock: number): boolean
	return IsSealedOrClosed(View, Index) or IsShort(View, Index, Count, Clock)
end

local function IsSoldOut(View: QuantityView, Parts: number): boolean
	for Index = 0, Parts - 1 do
		if not IsSealedOrClosed(View, Index) then
			return false
		end
	end
	return true
end

local function IsBusy(View: QuantityView, Parts: number, Count: number, Clock: number): boolean
	for Index = 0, Parts - 1 do
		if not IsPassed(View, Index, Count, Clock) then
			return false
		end
	end
	return not IsSoldOut(View, Parts)
end

local function DrawnOrder(
	Encoding: Encoding,
	Quantity: QuantityDeclaration,
	ServerNumber: number,
	View: QuantityView,
	Count: number,
	Clock: number
): { number }
	local Home = HomePart(Encoding, Quantity, ServerNumber)
	local Order: { number } = {}
	if not IsPassed(View, Home, Count, Clock) then
		table.insert(Order, Home)
	end
	local Shown: { FreeAt } = {}
	local Unseen: { number } = {}
	for Index = 0, Quantity.Parts - 1 do
		if Index == Home or IsPassed(View, Index, Count, Clock) then
			continue
		end
		local Entry = View.Parts[Index]
		if Entry == nil then
			table.insert(Unseen, Index)
		else
			table.insert(Shown, { Index = Index, Free = Entry.Free })
		end
	end
	table.sort(Shown, function(Left: FreeAt, Right: FreeAt): boolean
		if Left.Free ~= Right.Free then
			return Left.Free > Right.Free
		end
		return Left.Index < Right.Index
	end)
	for _, Seen in Shown do
		table.insert(Order, Seen.Index)
	end
	table.move(Unseen, 1, #Unseen, #Order + 1, Order)
	return Order
end

local function EntryOfState(Q: number, Stored: Fields): ViewEntry
	local Record = Part.RecordOf(Stored)
	return {
		Q = Q,
		Free = Part.FreeOf(Stored),
		Held = Holds.HeldUnits(Record),
		Sold = Record.Sold,
		IsSealed = Record.IsSealed,
		IsClosed = Record.IsClosed,
	}
end

local function EntryOfRead(Read: StoredRead): ViewEntry?
	if Read.Kind == "Kept" then
		return EntryOfState(Read.Kept.Book.Writes, Read.Kept.State)
	end
	if Read.Kind == "Nothing" then
		return AbsentEntry
	end
	return nil
end

local function Merge(View: QuantityView, Index: number, Entry: ViewEntry): ()
	local Known = View.Parts[Index]
	if Known == nil then
		View.Parts[Index] = Entry
		if Entry.Q > 0 then
			View.AbsentAt[Index] = nil
		end
		return
	end
	if Entry.Q <= Known.Q then
		return
	end
	View.AbsentAt[Index] = nil
	View.Parts[Index] = {
		Q = Entry.Q,
		Free = Entry.Free,
		Held = Entry.Held,
		Sold = Entry.Sold,
		IsSealed = Entry.IsSealed or Known.IsSealed,
		IsClosed = Entry.IsClosed or Known.IsClosed,
	}
end

local function NoteAbsent(View: QuantityView, Index: number, Clock: number): ()
	local Known = View.Parts[Index]
	if Known == nil or Known.Q == 0 then
		View.AbsentAt[Index] = Clock
	end
end

local function IsPresent(View: QuantityView, Index: number): boolean
	local Known = View.Parts[Index]
	return Known ~= nil and Known.Q > 0
end

local function IsAbsentNow(View: QuantityView, Index: number, Clock: number): boolean
	local At = View.AbsentAt[Index]
	return At ~= nil and Clock - At <= ViewAge and not IsPresent(View, Index)
end

local function Lacking(View: QuantityView, Parts: number): { number }
	local Absent: { number } = {}
	for Index = 0, Parts - 1 do
		if View.Parts[Index] == nil then
			table.insert(Absent, Index)
		end
	end
	return Absent
end

local function QuantityOf(View: QuantityView, Parts: number): QuantityTotal
	local Sold, Free, Held = 0, 0, 0
	for Index = 0, Parts - 1 do
		local Entry = View.Parts[Index]
		if Entry == nil then
			error(QuantityNeedsEveryPart)
		end
		Sold += Entry.Sold
		Free += Entry.Free
		Held += Entry.Held
	end
	return { Sold = Sold, Free = Free, Held = Held }
end

local function NoteLanded(View: QuantityView, Index: number, Landed: LandedValue): ()
	Merge(View, Index, EntryOfState(Landed.Written.Book.Writes, Landed.Written.State))
end

local function NoteEnded(View: QuantityView, Index: number, Reason: PartReason, Shown: ViewEntry): ()
	Merge(View, Index, Shown)
	local Known = View.Parts[Index] or Shown
	View.Parts[Index] = {
		Q = Known.Q,
		Free = Known.Free,
		Held = Known.Held,
		Sold = Known.Sold,
		IsSealed = Known.IsSealed or Reason == PartReasons.Sealed,
		IsClosed = Known.IsClosed or Reason == PartReasons.Closed,
	}
end

local function EntryKnown(View: QuantityView, Index: number): ViewEntry
	local Known = View.Parts[Index]
	if Known == nil then
		return AbsentEntry
	end
	return Known
end

local function NoteRefusal(View: QuantityView, Index: number, Count: number, Clock: number): ()
	View.Refusals[Index] = { Count = Count, At = Clock }
end

local function NoteNo(
	View: QuantityView,
	Index: number,
	Reason: PartReason,
	Count: number,
	Clock: number,
	Shown: ViewEntry
): ()
	if Reason == PartReasons.Sealed or Reason == PartReasons.Closed then
		NoteEnded(View, Index, Reason, Shown)
		return
	end
	NoteRefusal(View, Index, Count, Clock)
end

return {
	GameOrder = GameOrder,
	HomePart = HomePart,
	IsPassed = IsPassed,
	IsSoldOut = IsSoldOut,
	IsBusy = IsBusy,
	DrawnOrder = DrawnOrder,
	EntryOfState = EntryOfState,
	EntryOfRead = EntryOfRead,
	Merge = Merge,
	Lacking = Lacking,
	QuantityOf = QuantityOf,
	NoteLanded = NoteLanded,
	NoteAbsent = NoteAbsent,
	IsPresent = IsPresent,
	IsAbsentNow = IsAbsentNow,
	EntryKnown = EntryKnown,
	NoteNo = NoteNo,
}
