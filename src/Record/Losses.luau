--!strict
--!optimize 2

--[=[
	Losses: Logic. The loss room: the events that name money a Reset destroyed, the named returns of
	the orphan rule, and the fold slots older events go into.

	Spec: cuts 2 and 5; transaction 5.1.

	The room never refuses. When an event makes it pass the build's LossRoom, Name folds the oldest
	reset events into exact sums per money field and per period of Windows.FOLD_SPAN, at most
	Book.SLOTS_MAX slots at a time, the newest event last. A named return never folds, and goes only
	once nothing else can. An event stamped ahead of the clock, or one wanting a third period, cannot
	fold yet, and Name gives back the clock the caller must wait for. An event leaves at the build's
	KeepNamed, and a slot once its two periods are over. A sum is two limbs of Alphabet.LIMB, since
	it may pass 2^53.

	Return type: A table with Money, AddToSum, Name and Age.
	Example usage:
		local Wait = Losses.Name(Record, Build, Clock, Epoch, Event)
--]=]

local Alphabet = require("../Encode/Alphabet")
local Book = require("./Book")
local Types = require("./Types")
local Windows = require("../Core/Constants/Windows")

type State = { [string]: any }

local LIMB = Alphabet.LIMB
local FOLD_SPAN = Windows.FOLD_SPAN
local PERIODS = 2

local Cause = Book.Cause

local Losses = {}

local function Ends(Period: number): number
	return (Period + PERIODS) * FOLD_SPAN
end

local function SlotOf(Record: Book.Book, Period: number): Book.Slot?
	for _, Slot in Record.Slots do
		if Slot.Period == Period then
			return Slot
		end
	end
	if #Record.Slots >= Book.SLOTS_MAX then
		return nil
	end
	local Made: Book.Slot = { Period = Period, Count = 0, Sums = {} }
	table.insert(Record.Slots, Made)
	return Made
end

local function IsNamedReturn(Event: Book.Event): boolean
	return Event.Cause == Cause.Returned or Event.Cause == Cause.Orphan
end

local function EarlierOf(Held: number?, Clock: number): number
	return if Held then math.min(Held, Clock) else Clock
end

local function Fold(Record: Book.Book, Build: Types.Build, Now: number, Epoch: number): number?
	local function Over(): boolean
		return Book.LossWidth(Record.Events, Record.Slots, Epoch) > Build.LossRoom
	end
	if not Over() then
		return nil
	end
	local Newest = Record.Events[#Record.Events]
	local Order: { Book.Event } = {}
	for _, Event in Record.Events do
		if Event ~= Newest and not IsNamedReturn(Event) then
			table.insert(Order, Event)
		end
	end
	table.sort(Order, function(Left: Book.Event, Right: Book.Event): boolean
		return Left.Stamp < Right.Stamp
	end)
	if Newest and not IsNamedReturn(Newest) then
		table.insert(Order, Newest)
	end
	local Earliest: number? = nil
	for _, Event in Order do
		if not Over() then
			return nil
		end
		local Period = Event.Stamp // FOLD_SPAN
		local Slot = if Event.Stamp <= Now and Now < Ends(Period) then SlotOf(Record, Period) else nil
		if Now >= Ends(Period) then
			table.remove(Record.Events, table.find(Record.Events, Event) :: number)
		elseif Slot then
			for Field, Amount in Event.Amounts do
				local Sum = Slot.Sums[Field] or { High = 0, Low = 0 }
				Losses.AddToSum(Sum, Amount)
				Slot.Sums[Field] = Sum
			end
			Slot.Count += 1
			table.remove(Record.Events, table.find(Record.Events, Event) :: number)
		elseif Event.Stamp > Now then
			Earliest = EarlierOf(Earliest, Event.Stamp)
		else
			for _, Held in Record.Slots do
				Earliest = EarlierOf(Earliest, Ends(Held.Period))
			end
		end
	end
	while Over() do
		local Oldest: number? = nil
		for Index, Event in Record.Events do
			if IsNamedReturn(Event) and (Oldest == nil or Event.Stamp < Record.Events[Oldest].Stamp) then
				Oldest = Index
			end
		end
		if Oldest == nil then
			return Earliest or Now + 1
		end
		table.remove(Record.Events, Oldest)
	end
	return nil
end

function Losses.Money(State: State, Build: Types.Build): { [number]: number }
	local Amounts: { [number]: number } = {}
	for Index, Field in Build.Money do
		local Amount = State[Field]
		if type(Amount) == "number" and Amount ~= 0 then
			Amounts[Index] = Amount
		end
	end
	return Amounts
end

function Losses.AddToSum(Sum: Book.Sum, Amount: number)
	Sum.High += Amount // LIMB
	Sum.Low += Amount % LIMB
	if Sum.Low >= LIMB then
		Sum.High += 1
		Sum.Low -= LIMB
	end
end

function Losses.Name(Record: Book.Book, Build: Types.Build, Now: number, Epoch: number, Event: Book.Event): number?
	table.insert(Record.Events, Event)
	return Fold(Record, Build, Now, Epoch)
end

function Losses.Age(Record: Book.Book, Build: Types.Build, Now: number): boolean
	local Held = #Record.Events + #Record.Slots
	local Events: { Book.Event } = {}
	for _, Event in Record.Events do
		if Now - Event.Stamp < Build.KeepNamed then
			table.insert(Events, Event)
		end
	end
	Record.Events = Events
	local Slots: { Book.Slot } = {}
	for _, Slot in Record.Slots do
		if Now < Ends(Slot.Period) then
			table.insert(Slots, Slot)
		end
	end
	Record.Slots = Slots
	return #Events + #Slots < Held
end

return Losses
