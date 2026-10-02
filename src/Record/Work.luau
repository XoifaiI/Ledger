--!strict
--!optimize 2

--[=[

	Work: Logic. A transaction's steps on one key, run inside Step.

	Spec: transaction 3.2 to 3.5, and 4.1.

	Ends applies the resolves and drops a request carries, before anything else. A resolve of commit
	applies the mark of its own attempt. An escrow mark adds its amount to its field, and an
	exclusive mark lays its post diff on the state. A resolve of abort takes off the mark of its
	attempt or an older one. A resolve of commit for a newer attempt does the same. An exclusive
	mark with a slot writes the decider value the resolve carries at its slot. Without that value it
	ends nothing and says the build is behind. An orphan end, which a touch sends when the decider
	reads gone, takes off the mark of any attempt. Each writes the leg's fate. A resolve ends only a
	mark whose fingerprint it carries, and one that finds no mark writes the fate a later Tent must
	meet. A resolve of commit on a money field this build does not know ends nothing and says the
	build is behind. A drop moves a pinned record to the timed room as a decision that took. An
	orphan end adds a named return to the loss room: Returned, with the mark's field, amount and
	decider. A drop of a pinned record whose leg key reads gone adds Orphan, with that leg key.

	Tent sets an escrow mark for a field delta, judged against the least and the most the field can
	end at. The build's Accepts judges it too. For a game op it sets an exclusive mark and its post
	diff, which needs a key with no other mark. It never changes the state. Commit applies the
	decider's own leg by the order rule and pins the record of the use. A commit with no other legs
	keeps its decision at once instead. Each keeps the decider value the build's Output gives, and
	the note carries it. Fence writes the decision fenced at an attempt. No commit of that attempt
	or a lower one lands after it, and none at all once the fence is final. A Tent that meets a
	cut's gate, and a Commit that meets an erase's, is Gated. Each step says what it found on the
	note. That is its report, the attempt and fate it read, the items that blocked or crowded it,
	and the gate it met.

	Return type: A table with Ends, Tent, Commit and Fence.
	Example usage:
		Work.Ends(Run)
--]=]

local Book = require("./Book")
local Cuts = require("./Cuts")
local Diff = require("./Diff")
local Guard = require("./Guard")
local Limits = require("../Core/Constants/Limits")
local Marks = require("./Marks")
local Migrate = require("./Migrate")
local Reduce = require("../Core/Reduce")
local Rooms = require("./Rooms")
local Rules = require("./Rules")
local Sizes = require("../Core/Constants/Sizes")
local Types = require("./Types")
local Value = require("../Encode/Value")

type Run = Rules.Run
type State = { [string]: any }
type Items = { [string]: Book.Work }

local Fate = Book.Fate
local Role = Book.Role
local Report = Types.Report
local Outcome = Types.Outcome
local Why = Types.Why

local Work = {}

local function Say(Run: Run, Said: Types.Report, Attempt: number?, Code: number?, Final: boolean?)
	local Note = Run.Note
	Note.Report, Note.Attempt, Note.Fate, Note.Final = Said, Attempt, Code, Final
end

local function Listed(Run: Run, Said: Types.Report, Items: Items)
	Run.Note.Items = Items
	Say(Run, Said)
end

local function Fated(Held: Book.Named, Code: number, Attempt: number, Final: boolean?): Book.Named
	return {
		Kind = 0,
		Role = Held.Role,
		Stamp = Held.Stamp,
		Fate = Code,
		Attempt = Attempt,
		Print = Held.Print,
		Final = if Final then true else nil,
		Value = Held.Value,
	}
end

local function Named(Role: number, Stamp: number, Print: number?): Book.Named
	return { Kind = 0, Role = Role, Stamp = Stamp, Fate = Fate.Took, Print = Print }
end

local function Keep(Run: Run, Name: string, Item: Book.Named)
	Run.Record.Timed[Name] = Item
	Run.Written[Name] = true
	Run.Acted = true
end

local function Take(Run: Run, Name: string, Item: Book.Work)
	Run.Record.Work[Name] = nil
	if Item.Form == "Exclusive" then
		Run.Post = nil
	end
	Run.Acted = true
end

local function Crowded(Run: Run, Name: string, Item: Book.Work): boolean
	local Marked, Pinned = Rooms.Count(Run.Record)
	if Item.Form == "Pinned" and Pinned >= Sizes.OWED_CAP then
		return true
	elseif Item.Form ~= "Pinned" and Marked >= Sizes.MARK_CAP then
		return true
	end
	return Rooms.Work(Run.Record, Run.Epoch) + Book.WorkWidth(Name, Item, Run.Epoch) > Run.Build.WorkRoom
end

local function Pins(Record: Book.Book): Items
	local Found: Items = {}
	for Name, Item in Record.Work do
		if Item.Form == "Pinned" then
			Found[Name] = Item
		end
	end
	return Found
end

local function Exclusives(Record: Book.Book): Items
	local Found: Items = {}
	for Name, Item in Record.Work do
		if Item.Form == "Exclusive" then
			Found[Name] = Item
		end
	end
	return Found
end

local function Lift(Run: Run): boolean
	local Record, Build = Run.Record, Run.Build
	if Record.Level >= Build.Level then
		return true
	end
	local State = Migrate(Run.State, Record.Level, Build)
	if State == nil then
		return false
	end
	Record.Level, Record.Floor = Build.Level, math.max(Record.Floor, Build.Floor)
	Run.State, Run.Changed = State, true
	return true
end

local function Shifted(Run: Run, Field: number, Amount: number): State?
	local Name = Run.Build.Money[Field]
	local Held = if Name then Run.State[Name] else nil
	if type(Held) ~= "number" then
		return nil
	end
	local Next = table.clone(Run.State)
	Next[Name] = Held + Amount
	return Next
end

local function Refuses(Low: number?, High: number?, Amount: number): boolean
	if Low == nil or High == nil then
		return true
	end
	return if Amount < 0 then Low + Amount < 0 else High + Amount >= Limits.MONEY_LIMIT
end

local function Barred(Run: Run, Field: number, Amount: number): boolean
	local Accepts = Run.Build.Accepts
	return Accepts ~= nil and not Accepts(Run.State, Field, Amount)
end

local function Applied(Run: Run, Item: Book.Escrow | Book.Exclusive, Value: number?): boolean
	if Item.Form == "Exclusive" then
		local Post = table.clone(Run.Post or {})
		if Item.Slot and Value == nil then
			return false
		elseif Item.Slot then
			table.insert(Post, { k = Item.Slot, v = Value })
		end
		Run.State = Diff.Apply(Run.State, Post)
		Run.Changed = true
		return true
	end
	local Next = Shifted(Run, Item.Field, Item.Amount)
	if Next == nil then
		return false
	end
	Run.State, Run.Changed = Next, true
	return true
end

local function Return(Run: Run, Event: Book.Event)
	table.insert(Run.Record.Events, Event)
	Cuts.Fold(Run.Record, Run.Build, Run.Clock, Run.Epoch)
end

local function Resolve(Run: Run, End: Types.End)
	local Record, Name = Run.Record, End.Name
	local Item = Record.Work[Name]
	local Commit, Orphan = End.Outcome == Outcome.Commit, End.Outcome == Outcome.Orphan
	if Item and Item.Form ~= "Pinned" and Item.Print == End.Print then
		if Commit and Item.Attempt == End.Attempt then
			if Applied(Run, Item, End.Value) then
				Take(Run, Name, Item)
				Keep(Run, Name, Fated(Named(Role.Leg, Item.Stamp, Item.Print), Fate.Took, Item.Attempt))
			else
				Run.Note.Why = Why.Behind
			end
		elseif Orphan or Item.Attempt < End.Attempt or (not Commit and Item.Attempt == End.Attempt) then
			Take(Run, Name, Item)
			Keep(Run, Name, Fated(Named(Role.Leg, Item.Stamp, Item.Print), Fate.Aborted, Item.Attempt))
			if Orphan then
				local Amounts: { [number]: number } = if Item.Form == "Escrow" then { [Item.Field] = Item.Amount } else {}
				Return(Run, { Cause = Book.Cause.Returned, Name = Name, Stamp = Item.Stamp, Amounts = Amounts, Ref = Item.Decider })
			end
		end
		return
	end
	local Held = Record:Held(Name)
	if Held and Held.Role ~= Role.Leg then
		return
	elseif Held == nil and Item == nil and End.Stamp <= Record.Horizon then
		return
	elseif Commit then
		if Held == nil or Held.Fate ~= Fate.Took then
			Keep(Run, Name, Fated(Named(Role.Leg, End.Stamp, End.Print), Fate.Took, End.Attempt))
		end
	elseif Held == nil or (Held.Fate == Fate.Aborted and (Held.Attempt or 0) < End.Attempt) then
		Keep(Run, Name, Fated(Named(Role.Leg, End.Stamp, End.Print), Fate.Aborted, End.Attempt))
	end
end

local function Drop(Run: Run, Name: string, Gone: Book.Ref?)
	local Item = Run.Record.Work[Name]
	if Item and Item.Form == "Pinned" then
		Run.Record.Work[Name] = nil
		local Decision = Fated(Named(Role.Decision, Item.Stamp, Item.Print), Fate.Took, Item.Attempt)
		Decision.Value = Item.Value
		Keep(Run, Name, Decision)
		if Gone then
			Return(Run, { Cause = Book.Cause.Orphan, Name = Name, Stamp = Item.Stamp, Amounts = {}, Ref = Gone })
		end
	end
end

function Work.Ends(Run: Run)
	for _, End in Run.Request.Ends or {} do
		Resolve(Run, End)
	end
	for _, Name in Run.Request.Drops or {} do
		Drop(Run, Name)
	end
	for _, Orphan in Run.Request.Orphans or {} do
		Drop(Run, Orphan.Name, Orphan.Ref)
	end
end

local function Escrow(Run: Run, Tent: Types.Tent, Field: number, Amount: number)
	local Record = Run.Record
	local Blockers = Exclusives(Record)
	if next(Blockers) then
		return Listed(Run, Report.Blocked, Blockers)
	end
	local Low, High = Marks.Bounds(Record.Work, Run.State, Run.Build, Field)
	if Refuses(Low, High, Amount) or Barred(Run, Field, Amount) then
		Keep(Run, Tent.Name, Fated(Named(Role.Leg, Tent.Stamp, Tent.Print), Fate.Refused, Tent.Attempt))
		return Say(Run, Report.Refused, Tent.Attempt, Fate.Refused)
	end
	local Mark: Book.Escrow = {
		Form = "Escrow",
		Stamp = Tent.Stamp,
		Attempt = Tent.Attempt,
		Print = Tent.Print,
		Clean = true,
		Decider = Tent.Decider,
		Field = Field,
		Amount = Amount,
	}
	if Crowded(Run, Tent.Name, Mark) then
		return Listed(Run, Report.NoRoom, Marks.Standing(Record.Work))
	end
	Record.Work[Tent.Name] = Mark
	Run.Placed, Run.Acted = Tent.Name, true
	return Say(Run, Report.Mine, Tent.Attempt)
end

local function Exclusive(Run: Run, Tent: Types.Tent, Body: unknown)
	local Record = Run.Record
	local Standing = Marks.Standing(Record.Work)
	if next(Standing) then
		return Listed(Run, Report.Blocked, Standing)
	end
	local Next: State?, Reason: unknown = nil, nil
	if Lift(Run) then
		Next, _, Reason = Reduce.Run(Guard.Capped(Run.Build), Reduce.Copy(Run.State), Body)
	end
	if Next == nil then
		local Code = if Reason == Fate.Full then Fate.Full else Fate.Refused
		Keep(Run, Tent.Name, Fated(Named(Role.Leg, Tent.Stamp, Tent.Print), Code, Tent.Attempt))
		return Say(Run, Report.Refused, Tent.Attempt, Code)
	end
	local Changes = Diff.Make(Run.State, Next)
	local Bytes = Value.Check(Changes)
	if Bytes == nil or Bytes > Sizes.POST_CAP then
		return Say(Run, Report.Large)
	end
	local Mark: Book.Exclusive = {
		Form = "Exclusive",
		Stamp = Tent.Stamp,
		Attempt = Tent.Attempt,
		Print = Tent.Print,
		Clean = true,
		Decider = Tent.Decider,
		Slot = Tent.Leg.Slot,
	}
	if Crowded(Run, Tent.Name, Mark) then
		return Listed(Run, Report.NoRoom, Standing)
	end
	Record.Work[Tent.Name] = Mark
	Run.Post, Run.Placed, Run.Acted = Changes, Tent.Name, true
	return Say(Run, Report.Mine, Tent.Attempt)
end

local function Opens(Run: Run, Stamp: number): Types.Report?
	local Record, Build = Run.Record, Run.Build
	if Record.Floor > Build.Floor then
		return Report.Behind
	elseif Stamp > math.max(Run.Clock, Record.Horizon) + Build.Ahead then
		return Report.Ahead
	end
	return nil
end

function Work.Tent(Run: Run, Tent: Types.Tent)
	local Record, Name = Run.Record, Tent.Name
	local Item = Record.Work[Name]
	if Item and Item.Form ~= "Pinned" then
		if Item.Print ~= Tent.Print then
			return Say(Run, Report.Other)
		elseif Item.Attempt == Tent.Attempt then
			return Say(Run, Report.Mine, Item.Attempt)
		elseif Item.Attempt > Tent.Attempt then
			return Say(Run, Report.Superseded, Item.Attempt)
		end
		Take(Run, Name, Item)
	end
	local Held = Record:Held(Name)
	if Held and Held.Role == Role.Leg then
		if Held.Print ~= Tent.Print then
			return Say(Run, Report.Other)
		elseif not (Held.Fate == Fate.Aborted and (Held.Attempt or 0) < Tent.Attempt) then
			return Say(Run, Report.Decided, Held.Attempt, Held.Fate)
		end
	elseif Held or Record.Work[Name] then
		return Say(Run, Report.Other)
	elseif Tent.Stamp <= Record.Horizon then
		return Say(Run, Report.Forgotten)
	end
	local Stop = Opens(Run, Tent.Stamp)
	if Stop then
		return Say(Run, Stop)
	elseif Record.Gate then
		Run.Note.Gate = Record.Gate
		return Say(Run, Report.Gated)
	end
	local Leg = Tent.Leg
	if Leg.Field and Leg.Amount then
		return Escrow(Run, Tent, Leg.Field, Leg.Amount)
	end
	return Exclusive(Run, Tent, Leg.Body)
end

local function Refuse(Run: Run, Commit: Types.Commit, Code: number)
	Keep(Run, Commit.Name, Fated(Named(Role.Decision, Commit.Stamp, Commit.Print), Code, Commit.Attempt))
	Say(Run, Report.Refused, Commit.Attempt, Code)
end

local function Delta(Run: Run, Commit: Types.Commit, Field: number, Amount: number): State?
	local Blockers = Exclusives(Run.Record)
	if next(Blockers) then
		Listed(Run, Report.Blocked, Blockers)
		return nil
	end
	local Low, High = Marks.Bounds(Run.Record.Work, Run.State, Run.Build, Field)
	local Next = if Refuses(Low, High, Amount) or Barred(Run, Field, Amount) then nil else Shifted(Run, Field, Amount)
	if Next == nil then
		Refuse(Run, Commit, Fate.Refused)
	end
	return Next
end

local function Game(Run: Run, Commit: Types.Commit, Body: unknown): State?
	local Record = Run.Record
	local Standing = Marks.Standing(Record.Work)
	if Record.Level < Run.Build.Level and next(Standing) then
		Listed(Run, Report.Blocked, Standing)
		return nil
	elseif not Lift(Run) then
		Refuse(Run, Commit, Fate.Refused)
		return nil
	end
	local Blockers = Marks.Order(Record.Work, Run.Build, Run.Reducer, Run.State, Body)
	if Blockers then
		Listed(Run, Report.Blocked, Blockers)
		return nil
	end
	local Next, _, Reason = Reduce.Run(Run.Reducer, Reduce.Copy(Run.State), Body)
	if Next == nil then
		Refuse(Run, Commit, if Reason == Fate.Full then Fate.Full else Fate.Refused)
	end
	return Next
end

function Work.Commit(Run: Run, Commit: Types.Commit)
	local Record, Name = Run.Record, Commit.Name
	local Item = Record.Work[Name]
	if Item and Item.Form == "Pinned" then
		Run.Note.Value = Item.Value
		return Say(Run, if Item.Print == Commit.Print then Report.Committed else Report.Other, Item.Attempt)
	end
	local Held = Record:Held(Name)
	if Held and Held.Role == Role.Decision then
		local Attempt = Held.Attempt or 0
		if Held.Print ~= Commit.Print then
			return Say(Run, Report.Other)
		elseif Held.Fate == Fate.Took then
			Run.Note.Value = Held.Value
			return Say(Run, Report.Committed, Attempt)
		elseif Held.Fate ~= Fate.Fenced then
			return Say(Run, Report.Refused, Attempt, Held.Fate)
		elseif Held.Final or Attempt >= Commit.Attempt then
			return Say(Run, Report.Fenced, Attempt, Held.Fate, Held.Final == true)
		end
	elseif Held or Item then
		return Say(Run, Report.Other)
	elseif Commit.Stamp <= Record.Horizon then
		return Say(Run, Report.Forgotten)
	end
	local Stop = Opens(Run, Commit.Stamp)
	local Gate = Record.Gate
	if Stop then
		return Say(Run, Stop)
	elseif Gate and Gate.Kind == Book.Cause.Erase then
		Run.Note.Gate = Gate
		return Say(Run, Report.Gated)
	end
	local Leg = Commit.Leg
	local Next = if Leg.Field and Leg.Amount then Delta(Run, Commit, Leg.Field, Leg.Amount) else Game(Run, Commit, Leg.Body)
	if Next == nil then
		return
	end
	local Output = Run.Build.Output
	local Value = if Output then Output(Next) else nil
	Run.Note.Value = Value
	if Commit.Legs[1] == nil then
		local Decision = Fated(Named(Role.Decision, Commit.Stamp, Commit.Print), Fate.Took, Commit.Attempt)
		Decision.Value = Value
		Run.State, Run.Changed = Next, true
		Keep(Run, Name, Decision)
		return Say(Run, Report.Committed, Commit.Attempt)
	end
	local Pin: Book.Pinned = {
		Form = "Pinned",
		Stamp = Commit.Stamp,
		Attempt = Commit.Attempt,
		Print = Commit.Print,
		Legs = Commit.Legs,
		Value = Value,
	}
	if Crowded(Run, Name, Pin) then
		return Listed(Run, Report.Owed, Pins(Record))
	end
	Run.State, Run.Changed = Next, true
	Record.Timed[Name] = nil
	Record.Work[Name] = Pin
	Run.Acted = true
	return Say(Run, Report.Committed, Commit.Attempt)
end

function Work.Fence(Run: Run, Fence: Types.Fence)
	local Record, Name = Run.Record, Fence.Name
	local Item = Record.Work[Name]
	if Item and Item.Form == "Pinned" then
		Run.Note.Value = Item.Value
		return Say(Run, Report.Committed, Item.Attempt)
	end
	local Held = Record:Held(Name)
	if Held and Held.Role == Role.Decision then
		local Attempt = Held.Attempt or 0
		if Held.Fate == Fate.Took then
			Run.Note.Value = Held.Value
			return Say(Run, Report.Committed, Attempt)
		elseif Held.Fate ~= Fate.Fenced then
			return Say(Run, Report.Refused, Attempt, Held.Fate)
		elseif Attempt >= Fence.Attempt and (Held.Final or not Fence.Final) then
			return Say(Run, Report.Fenced, Attempt, Fate.Fenced, Held.Final == true)
		end
		local At, Final = math.max(Attempt, Fence.Attempt), Held.Final == true or Fence.Final
		Keep(Run, Name, Fated(Held, Fate.Fenced, At, Final))
		return Say(Run, Report.Fenced, At, Fate.Fenced, Final)
	elseif Held == nil and Item == nil and Fence.Stamp <= Record.Horizon then
		return Say(Run, Report.Forgotten)
	end
	Keep(Run, Name, Fated(Named(Role.Decision, Fence.Stamp, Fence.Print), Fate.Fenced, Fence.Attempt, Fence.Final))
	return Say(Run, Report.Fenced, Fence.Attempt, Fate.Fenced, Fence.Final)
end

return Work
