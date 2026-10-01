--!strict
--!optimize 2

--[=[

	Cuts: Logic. A Reset or an Erase inside Step, the gate it places, and the loss room that names
	the money it destroys.

	Spec: cuts 2, 3.1, 3.4 and 5.

	Judge runs a cut through the rules of cuts 3.1 in order. A name kept in the cut room took, or is
	Spent under other terms. The cut's own gate skips the horizon, ahead and helper rules. A stamp
	at or under the cut horizon is forgotten. A key whose floor or level this build lacks is behind.
	A helper with no gate of its own is gone. Another cut's gate is reported with the marks. Marks,
	and for an Erase every work item, are reported, and a cutter that finds no gate places its own
	in the same write. With none left, a Reset names every money field it destroys as an event. It
	replaces the state with its given state or the default. It counts the cut and keeps its name. An
	Erase makes a seal of its namings instead. Fold makes room in the loss room as cuts 5 says, and
	gives back the clock a cut must wait for when it cannot. Age drops a gate the cut window has
	passed, and raises the cut horizon. It drops an event past KeepNamed, and a slot whose two
	periods are over. It says whether it dropped any. Money gives the amount of each money field
	that is not 0, and Add puts one amount into an exact sum.

	Return type: A table with Judge, Fold, Age, Money, Add and Width.
	Example usage:
		Cuts.Judge(Run, Request.Cut)
--]=]

local Alphabet = require("../Encode/Alphabet")
local Book = require("./Book")
local Marks = require("./Marks")
local Reduce = require("../Core/Reduce")
local Rules = require("./Rules")
local Types = require("./Types")
local Windows = require("../Core/Constants/Windows")

type Run = Rules.Run
type State = { [string]: any }
type Items = { [string]: Book.Work }

local LIMB = Alphabet.LIMB
local FOLD_SPAN = Windows.FOLD_SPAN
local SLOTS_MAX = 2
local PERIODS = 2
local COUNTS_WIDTH = 4

local Cause = Book.Cause
local Fate = Book.Fate
local Report = Types.Report

local Cuts = {}

local function Say(Run: Run, Said: Types.Report, Items: Items?)
	Run.Note.Report = Said
	Run.Note.Items = Items
end

function Cuts.Money(State: State, Build: Types.Build): { [number]: number }
	local Amounts: { [number]: number } = {}
	for Index, Field in Build.Money do
		local Amount = State[Field]
		if type(Amount) == "number" and Amount ~= 0 then
			Amounts[Index] = Amount
		end
	end
	return Amounts
end

function Cuts.Add(Sum: Book.Sum, Amount: number)
	Sum.High += Amount // LIMB
	Sum.Low += Amount % LIMB
	if Sum.Low >= LIMB then
		Sum.High += 1
		Sum.Low -= LIMB
	end
end

function Cuts.Width(Record: Book.Book, Now: number): number
	local Total = COUNTS_WIDTH
	for _, Event in Record.Events do
		Total += Book.EventWidth(Event, Now)
	end
	for _, Slot in Record.Slots do
		Total += Book.SlotWidth(Slot)
	end
	return Total
end

local function Ends(Period: number): number
	return (Period + PERIODS) * FOLD_SPAN
end

local function SlotOf(Record: Book.Book, Period: number): Book.Slot?
	for _, Slot in Record.Slots do
		if Slot.Period == Period then
			return Slot
		end
	end
	if #Record.Slots >= SLOTS_MAX then
		return nil
	end
	local Made: Book.Slot = { Period = Period, Count = 0, Sums = {} }
	table.insert(Record.Slots, Made)
	return Made
end

local function Returned(Event: Book.Event): boolean
	return Event.Cause == Cause.Returned or Event.Cause == Cause.Orphan
end

function Cuts.Fold(Record: Book.Book, Build: Types.Build, Now: number, Epoch: number): number?
	local function Over(): boolean
		return Cuts.Width(Record, Epoch) > Build.LossRoom
	end
	if not Over() then
		return nil
	end
	local Newest = Record.Events[#Record.Events]
	local Order: { Book.Event } = {}
	for _, Event in Record.Events do
		if Event ~= Newest and not Returned(Event) then
			table.insert(Order, Event)
		end
	end
	table.sort(Order, function(Left: Book.Event, Right: Book.Event): boolean
		return Left.Stamp < Right.Stamp
	end)
	if Newest and not Returned(Newest) then
		table.insert(Order, Newest)
	end
	local Waits = math.huge
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
				Cuts.Add(Sum, Amount)
				Slot.Sums[Field] = Sum
			end
			Slot.Count += 1
			table.remove(Record.Events, table.find(Record.Events, Event) :: number)
		elseif Event.Stamp > Now then
			Waits = math.min(Waits, Event.Stamp)
		else
			for _, Held in Record.Slots do
				Waits = math.min(Waits, Ends(Held.Period))
			end
		end
	end
	while Over() do
		local Oldest: number? = nil
		for Index, Event in Record.Events do
			if Returned(Event) and (Oldest == nil or Event.Stamp < Record.Events[Oldest].Stamp) then
				Oldest = Index
			end
		end
		if Oldest == nil then
			return if Waits == math.huge then Now + 1 else Waits
		end
		table.remove(Record.Events, Oldest)
	end
	return nil
end

function Cuts.Age(Record: Book.Book, Build: Types.Build, Now: number): boolean
	local Gate = Record.Gate
	local Held = #Record.Events + #Record.Slots
	if Gate and Now - Gate.Stamp >= Build.CutWindow then
		Record.Gate = nil
		Record.CutHorizon = math.max(Record.CutHorizon, Gate.Stamp)
	end
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
	return Record.Gate ~= Gate or #Events + #Slots < Held
end

local function Seal(Run: Run, Cut: Types.Cut)
	local Record = Run.Record
	local Events = table.clone(Record.Events)
	local Amounts = Cuts.Money(Run.State, Run.Build)
	if next(Amounts) then
		table.insert(Events, { Cause = Cause.Erase, Name = Cut.Name, Stamp = Run.Clock, Amounts = Amounts })
	end
	local Made: Book.Seal = {
		Name = Cut.Name,
		Stamp = Cut.Stamp,
		Print = Cut.Print,
		Server = Cut.Server,
		Rt = Run.Clock,
		Events = Events,
		Slots = table.clone(Record.Slots),
	}
	Run.Sealed, Run.Note.Seal, Run.Acted = Made, Made, true
	Say(Run, Report.Sealed)
end

local function Reset(Run: Run, Cut: Types.Cut)
	local Record, Build = Run.Record, Run.Build
	local Amounts = Cuts.Money(Run.State, Build)
	if next(Amounts) then
		local Events, Slots = table.clone(Record.Events), Reduce.Copy(Record.Slots)
		table.insert(Record.Events, { Cause = Cause.Reset, Name = Cut.Name, Stamp = Run.Clock, Amounts = Amounts })
		local Wait = Cuts.Fold(Record, Build, Run.Clock, Run.Epoch)
		if Wait then
			Record.Events, Record.Slots = Events, Slots
			Run.Note.Wait = Wait
			return Say(Run, Report.Wait)
		end
	end
	Run.State = Reduce.Copy(Cut.State or Run.Given or Build.Default)
	Record.Level, Record.Floor = Build.Level, Build.Floor
	Record.Cuts += 1
	Record.Cut[Cut.Name] = { Kind = Cut.Kind, Stamp = Cut.Stamp, Fate = Fate.Took, Print = Cut.Print }
	Run.Written[Cut.Name] = true
	if Record.Gate and Record.Gate.Name == Cut.Name then
		Record.Gate = nil
	end
	Run.Given, Run.Post = nil, nil
	Run.Changed, Run.Acted = true, true
	Say(Run, Report.Took)
end

function Cuts.Judge(Run: Run, Cut: Types.Cut)
	local Record, Build = Run.Record, Run.Build
	local Kept = Record.Cut[Cut.Name]
	if Kept then
		return Say(Run, if Kept.Kind == Cut.Kind and Kept.Print == Cut.Print then Report.Took else Report.Spent)
	end
	local Gate = Record.Gate
	local Own = Gate ~= nil and Gate.Name == Cut.Name
	if Gate and Own and (Gate.Kind ~= Cut.Kind or Gate.Print ~= Cut.Print) then
		return Say(Run, Report.Spent)
	elseif not Own and Cut.Stamp <= Record.CutHorizon then
		return Say(Run, Report.Forgotten)
	elseif Record.Floor > Build.Floor or Record.Level > Build.Level then
		return Say(Run, Report.Behind)
	elseif Run.Now == nil or (not Own and Cut.Stamp > math.max(Run.Clock, Record.CutHorizon) + Build.Ahead) then
		return Say(Run, Report.Ahead)
	elseif not Own and Cut.Helper then
		return Say(Run, Report.Gone)
	elseif Gate and not Own then
		Run.Note.Gate = Gate
		return Say(Run, Report.GatedBy, Marks.Standing(Record.Work))
	end
	local Standing = if Cut.Kind == Cause.Erase then table.clone(Record.Work) else Marks.Standing(Record.Work)
	if next(Standing) then
		if Gate == nil and not Cut.Helper then
			Record.Gate = { Name = Cut.Name, Stamp = Cut.Stamp, Kind = Cut.Kind, Print = Cut.Print, At = Run.Clock }
			Run.Given, Run.Acted = Cut.State, true
		end
		return Say(Run, Report.Marks, Standing)
	elseif Cut.Kind == Cause.Erase then
		return Seal(Run, Cut)
	end
	return Reset(Run, Cut)
end

return Cuts
