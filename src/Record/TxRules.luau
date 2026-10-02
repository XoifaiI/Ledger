--!strict
--!optimize 2

--[=[
	TxRules: Logic. A transaction's steps on one key, run inside Step.

	Spec: transaction 3.2 to 3.5 and 4.1.

	A Tent is a transaction's prepare: it lands a mark on a leg key that is not the decider, and never
	changes the state. A field delta sets money aside in an escrow mark. A game op stores the change
	its reducer made in an exclusive mark, alone on its key, and its resolve lays that change on with
	no reducer run, so any build can end it. The decider decides in the write that applies its own
	leg, and pins the use until every leg key is resolved. A step names its use by name, attempt and
	fingerprint, and a resolve or fence of another attempt or fingerprint ends nothing it should not.
	A resolve that finds no mark still writes the leg's fate, so a late Tent of that attempt meets it.
	A mark of a money field or a slot this build does not know ends nothing, and says Behind.

	Return type: A table with Ends, Tent, Commit and Fence.
	Example usage:
		TxRules.Ends(Run)
--]=]

local Book = require("./Book")
local Diff = require("./Diff")
local Guard = require("./Guard")
local Limits = require("../Core/Constants/Limits")
local Losses = require("./Losses")
local Marks = require("./Marks")
local Migrate = require("./Migrate")
local Reduce = require("../Core/Reduce")
local Requests = require("./Requests")
local Rooms = require("./Rooms")
local Runs = require("./Runs")
local Sizes = require("../Core/Constants/Sizes")
local Types = require("./Types")
local Value = require("../Encode/Value")

type Run = Runs.Run
type State = { [string]: any }

local WorkForm = Book.WorkForm
local Fate = Book.Fate
local Role = Book.Role
local Report = Types.Report
local Outcome = Requests.Outcome
local Why = Types.Why

local TxRules = {}

local function WriteFate(Run: Run, Name: string, Item: Book.Named)
	Run.Record.Timed[Name] = Item
	Run.Written[Name] = true
	Run.Acted = true
end

local function RemoveMark(Run: Run, Name: string, Item: Book.Work)
	Run.Record.Work[Name] = nil
	if Item.Form == WorkForm.Exclusive then
		Run.Post = nil
	end
	Run.Acted = true
end

local function Crowded(Run: Run, Name: string, Item: Book.Work): boolean
	local Marked, Pinned = Rooms.Count(Run.Record)
	if Item.Form == WorkForm.Pinned and Pinned >= Sizes.OWED_CAP then
		return true
	elseif Item.Form ~= WorkForm.Pinned and Marked >= Sizes.MARK_CAP then
		return true
	end
	return Rooms.Work(Run.Record, Run.Epoch) + Book.WorkWidth(Name, Item, Run.Epoch) > Run.Build.WorkRoom
end

local function RunMigrations(Run: Run): boolean
	local Record, Build = Run.Record, Run.Build
	if Record.Level >= Build.Level then
		return true
	end
	local State = Migrate(Run.State, Record.Level, Build)
	if State == nil then
		return false
	end
	Record.Level = Build.Level
	Record.Floor = math.max(Record.Floor, Build.Floor)
	Run.State = State
	Run.Changed = true
	return true
end

local function AddToField(Run: Run, Field: number, Amount: number): State?
	local Name = Run.Build.Money[Field]
	local Held = if Name then Run.State[Name] else nil
	if type(Held) ~= "number" then
		return nil
	end
	local Next = table.clone(Run.State)
	Next[Name] = Held + Amount
	return Next
end

local function MoveMoney(Run: Run, Field: number, Amount: number): State?
	local Low, High = Marks.Bounds(Run.Record.Work, Run.State, Run.Build, Field)
	if Low == nil or High == nil then
		return nil
	elseif Amount < 0 and Low + Amount < 0 then
		return nil
	elseif Amount >= 0 and High + Amount >= Limits.MONEY_LIMIT then
		return nil
	end
	local Accepts = Run.Build.Accepts
	if Accepts and not Accepts(Run.State, Field, Amount) then
		return nil
	end
	return AddToField(Run, Field, Amount)
end

local function ApplyExclusive(Run: Run, Mark: Book.Exclusive, Value: number?): State?
	local Post = table.clone(Run.Post or {})
	if Mark.Slot and Value == nil then
		return nil
	elseif Mark.Slot then
		table.insert(Post, { k = Mark.Slot, v = Value })
	end
	return Diff.Apply(Run.State, Post)
end

local function ApplyMark(Run: Run, Mark: Book.Escrow | Book.Exclusive, Value: number?): State?
	if Mark.Form == WorkForm.Escrow then
		return AddToField(Run, Mark.Field, Mark.Amount)
	elseif Mark.Form == WorkForm.Exclusive then
		return ApplyExclusive(Run, Mark, Value)
	end
	error("TxRules: a mark of no known form", 0)
end

local function Resolve(Run: Run, End: Requests.End)
	local Record, Name = Run.Record, End.Name
	local Item = Record.Work[Name]
	local Commit = End.Outcome == Outcome.Commit
	local Orphan = End.Outcome == Outcome.Orphan
	local Mark = if Item then Book.AsMark(Item) else nil
	if Mark and Mark.Print == End.Print then
		if Commit and Mark.Attempt == End.Attempt then
			local Next = ApplyMark(Run, Mark, End.Value)
			if Next == nil then
				Run.Note.Why = Why.Behind
				return
			end
			Run.State = Next
			Run.Changed = true
			RemoveMark(Run, Name, Mark)
			WriteFate(Run, Name, Book.LegFate(Mark.Stamp, Mark.Print, Fate.Took, Mark.Attempt))
		elseif Orphan or Mark.Attempt < End.Attempt or (not Commit and Mark.Attempt == End.Attempt) then
			RemoveMark(Run, Name, Mark)
			WriteFate(Run, Name, Book.LegFate(Mark.Stamp, Mark.Print, Fate.Aborted, Mark.Attempt))
			if Orphan then
				local Amounts: { [number]: number } = if Mark.Form == WorkForm.Escrow then { [Mark.Field] = Mark.Amount } else {}
				Losses.Name(Record, Run.Build, Run.Clock, Run.Epoch, { Cause = Book.Cause.Returned, Name = Name, Stamp = Mark.Stamp, Amounts = Amounts, Ref = Mark.Decider })
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
			WriteFate(Run, Name, Book.LegFate(End.Stamp, End.Print, Fate.Took, End.Attempt))
		end
	elseif Held == nil or (Held.Fate == Fate.Aborted and (Held.Attempt or 0) < End.Attempt) then
		WriteFate(Run, Name, Book.LegFate(End.Stamp, End.Print, Fate.Aborted, End.Attempt))
	end
end

local function Drop(Run: Run, Name: string, Gone: Book.Ref?)
	local Item = Run.Record.Work[Name]
	local Pinned = if Item then Book.AsPinned(Item) else nil
	if Pinned == nil then
		return
	end
	Run.Record.Work[Name] = nil
	WriteFate(Run, Name, Book.Decision(Pinned.Stamp, Pinned.Print, Fate.Took, Pinned.Attempt, nil, Pinned.Value))
	if Gone then
		Losses.Name(Run.Record, Run.Build, Run.Clock, Run.Epoch, { Cause = Book.Cause.Orphan, Name = Name, Stamp = Pinned.Stamp, Amounts = {}, Ref = Gone })
	end
end

local function SetEscrowMark(Run: Run, Tent: Requests.Tent, Field: number, Amount: number)
	local Record = Run.Record
	local Blockers = Book.Of(Record.Work, WorkForm.Exclusive)
	if next(Blockers) then
		return Runs.ReportItems(Run, Report.Blocked, Blockers)
	end
	if MoveMoney(Run, Field, Amount) == nil then
		WriteFate(Run, Tent.Name, Book.LegFate(Tent.Stamp, Tent.Print, Fate.Refused, Tent.Attempt))
		return Runs.Report(Run, Report.Refused, Tent.Attempt, Fate.Refused)
	end
	local Mark: Book.Escrow = {
		Form = WorkForm.Escrow,
		Stamp = Tent.Stamp,
		Attempt = Tent.Attempt,
		Print = Tent.Print,
		Clean = true,
		Decider = Tent.Decider,
		Field = Field,
		Amount = Amount,
	}
	if Crowded(Run, Tent.Name, Mark) then
		return Runs.ReportItems(Run, Report.NoRoom, Book.Marks(Record.Work))
	end
	Record.Work[Tent.Name] = Mark
	Run.Placed = Tent.Name
	Run.Acted = true
	return Runs.Report(Run, Report.Mine, Tent.Attempt)
end

local function SetExclusiveMark(Run: Run, Tent: Requests.Tent, Body: unknown)
	local Record = Run.Record
	local Standing = Book.Marks(Record.Work)
	if next(Standing) then
		return Runs.ReportItems(Run, Report.Blocked, Standing)
	end
	local Next: State?, Reason: unknown = nil, nil
	if RunMigrations(Run) then
		Next, _, Reason = Reduce.Run(Guard.Capped(Run.Build), Reduce.Copy(Run.State), Body)
	end
	if Next == nil then
		local Code = if Reason == Fate.Full then Fate.Full else Fate.Refused
		WriteFate(Run, Tent.Name, Book.LegFate(Tent.Stamp, Tent.Print, Code, Tent.Attempt))
		return Runs.Report(Run, Report.Refused, Tent.Attempt, Code)
	end
	local Changes = Diff.Make(Run.State, Next)
	local Bytes = Value.Check(Changes)
	if Bytes == nil or Bytes > Sizes.POST_CAP then
		return Runs.Report(Run, Report.Large)
	end
	local Mark: Book.Exclusive = {
		Form = WorkForm.Exclusive,
		Stamp = Tent.Stamp,
		Attempt = Tent.Attempt,
		Print = Tent.Print,
		Clean = true,
		Decider = Tent.Decider,
		Slot = Tent.Leg.Slot,
	}
	if Crowded(Run, Tent.Name, Mark) then
		return Runs.ReportItems(Run, Report.NoRoom, Standing)
	end
	Record.Work[Tent.Name] = Mark
	Run.Post = Changes
	Run.Placed = Tent.Name
	Run.Acted = true
	return Runs.Report(Run, Report.Mine, Tent.Attempt)
end

local function BehindOrAhead(Run: Run, Stamp: number): Types.Report?
	local Record, Build = Run.Record, Run.Build
	if Record.Floor > Build.Floor then
		return Report.Behind
	elseif Stamp > math.max(Run.Clock, Record.Horizon) + Build.Ahead then
		return Report.Ahead
	end
	return nil
end

local function RefuseCommit(Run: Run, Commit: Requests.Commit, Code: number)
	WriteFate(Run, Commit.Name, Book.Decision(Commit.Stamp, Commit.Print, Code, Commit.Attempt))
	Runs.Report(Run, Report.Refused, Commit.Attempt, Code)
end

local function CommitDelta(Run: Run, Commit: Requests.Commit, Field: number, Amount: number): State?
	local Blockers = Book.Of(Run.Record.Work, WorkForm.Exclusive)
	if next(Blockers) then
		Runs.ReportItems(Run, Report.Blocked, Blockers)
		return nil
	end
	local Next = MoveMoney(Run, Field, Amount)
	if Next == nil then
		RefuseCommit(Run, Commit, Fate.Refused)
	end
	return Next
end

local function CommitGameOp(Run: Run, Commit: Requests.Commit, Body: unknown): State?
	local Record = Run.Record
	local Standing = Book.Marks(Record.Work)
	if Record.Level < Run.Build.Level and next(Standing) then
		Runs.ReportItems(Run, Report.Blocked, Standing)
		return nil
	elseif not RunMigrations(Run) then
		RefuseCommit(Run, Commit, Fate.Refused)
		return nil
	end
	local Blockers = Marks.Order(Record.Work, Run.Build, Run.Reducer, Run.State, Body)
	if Blockers then
		Runs.ReportItems(Run, Report.Blocked, Blockers)
		return nil
	end
	local Next, _, Reason = Reduce.Run(Run.Reducer, Reduce.Copy(Run.State), Body)
	if Next == nil then
		RefuseCommit(Run, Commit, if Reason == Fate.Full then Fate.Full else Fate.Refused)
	end
	return Next
end

function TxRules.Ends(Run: Run)
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

function TxRules.Tent(Run: Run, Tent: Requests.Tent)
	local Record, Name = Run.Record, Tent.Name
	local Item = Record.Work[Name]
	if Item and Item.Form ~= WorkForm.Pinned then
		if Item.Print ~= Tent.Print then
			return Runs.Report(Run, Report.Other)
		elseif Item.Attempt == Tent.Attempt then
			return Runs.Report(Run, Report.Mine, Item.Attempt)
		elseif Item.Attempt > Tent.Attempt then
			return Runs.Report(Run, Report.Superseded, Item.Attempt)
		end
		RemoveMark(Run, Name, Item)
	end
	local Held = Record:Held(Name)
	if Held and Held.Role == Role.Leg then
		if Held.Print ~= Tent.Print then
			return Runs.Report(Run, Report.Other)
		elseif not (Held.Fate == Fate.Aborted and (Held.Attempt or 0) < Tent.Attempt) then
			return Runs.Report(Run, Report.Decided, Held.Attempt, Held.Fate)
		end
	elseif Held or Record.Work[Name] then
		return Runs.Report(Run, Report.Other)
	elseif Tent.Stamp <= Record.Horizon then
		return Runs.Report(Run, Report.Forgotten)
	end
	local Stop = BehindOrAhead(Run, Tent.Stamp)
	if Stop then
		return Runs.Report(Run, Stop)
	elseif Record.Gate then
		Run.Note.Gate = Record.Gate
		return Runs.Report(Run, Report.Gated)
	end
	local Leg = Tent.Leg
	if Leg.Field and Leg.Amount then
		return SetEscrowMark(Run, Tent, Leg.Field, Leg.Amount)
	end
	return SetExclusiveMark(Run, Tent, Leg.Body)
end

function TxRules.Commit(Run: Run, Commit: Requests.Commit)
	local Record, Name = Run.Record, Commit.Name
	local Item = Record.Work[Name]
	if Item and Item.Form == WorkForm.Pinned then
		Run.Note.Value = Item.Value
		return Runs.Report(Run, if Item.Print == Commit.Print then Report.Committed else Report.Other, Item.Attempt)
	end
	local Held = Record:Held(Name)
	if Held and Held.Role == Role.Decision then
		local Attempt = Held.Attempt or 0
		if Held.Print ~= Commit.Print then
			return Runs.Report(Run, Report.Other)
		elseif Held.Fate == Fate.Took then
			Run.Note.Value = Held.Value
			return Runs.Report(Run, Report.Committed, Attempt)
		elseif Held.Fate ~= Fate.Fenced then
			return Runs.Report(Run, Report.Refused, Attempt, Held.Fate)
		elseif Held.Final or Attempt >= Commit.Attempt then
			return Runs.Report(Run, Report.Fenced, Attempt, Held.Fate, Held.Final == true)
		end
	elseif Held or Item then
		return Runs.Report(Run, Report.Other)
	elseif Commit.Stamp <= Record.Horizon then
		return Runs.Report(Run, Report.Forgotten)
	end
	local Stop = BehindOrAhead(Run, Commit.Stamp)
	local Gate = Record.Gate
	if Stop then
		return Runs.Report(Run, Stop)
	elseif Gate and Gate.Kind == Book.Cause.Erase then
		Run.Note.Gate = Gate
		return Runs.Report(Run, Report.Gated)
	end
	local Leg = Commit.Leg
	local Next = if Leg.Field and Leg.Amount then CommitDelta(Run, Commit, Leg.Field, Leg.Amount) else CommitGameOp(Run, Commit, Leg.Body)
	if Next == nil then
		return
	end
	local Output = Run.Build.Output
	local Value = if Output then Output(Next) else nil
	Run.Note.Value = Value
	if Commit.Legs[1] == nil then
		Run.State = Next
		Run.Changed = true
		WriteFate(Run, Name, Book.Decision(Commit.Stamp, Commit.Print, Fate.Took, Commit.Attempt, nil, Value))
		return Runs.Report(Run, Report.Committed, Commit.Attempt)
	end
	local Pin: Book.Pinned = {
		Form = WorkForm.Pinned,
		Stamp = Commit.Stamp,
		Attempt = Commit.Attempt,
		Print = Commit.Print,
		Legs = Commit.Legs,
		Value = Value,
	}
	if Crowded(Run, Name, Pin) then
		return Runs.ReportItems(Run, Report.Owed, Book.Of(Record.Work, WorkForm.Pinned))
	end
	Run.State = Next
	Run.Changed = true
	Record.Timed[Name] = nil
	Record.Work[Name] = Pin
	Run.Acted = true
	return Runs.Report(Run, Report.Committed, Commit.Attempt)
end

function TxRules.Fence(Run: Run, Fence: Requests.Fence)
	local Record, Name = Run.Record, Fence.Name
	local Item = Record.Work[Name]
	if Item and Item.Form == WorkForm.Pinned then
		Run.Note.Value = Item.Value
		return Runs.Report(Run, Report.Committed, Item.Attempt)
	end
	local Held = Record:Held(Name)
	if Held and Held.Role == Role.Decision then
		local Attempt = Held.Attempt or 0
		if Held.Fate == Fate.Took then
			Run.Note.Value = Held.Value
			return Runs.Report(Run, Report.Committed, Attempt)
		elseif Held.Fate ~= Fate.Fenced then
			return Runs.Report(Run, Report.Refused, Attempt, Held.Fate)
		elseif Attempt >= Fence.Attempt and (Held.Final or not Fence.Final) then
			return Runs.Report(Run, Report.Fenced, Attempt, Fate.Fenced, Held.Final == true)
		end
		local At = math.max(Attempt, Fence.Attempt)
		local Final = Held.Final == true or Fence.Final
		WriteFate(Run, Name, Book.Decision(Held.Stamp, Held.Print, Fate.Fenced, At, Final, Held.Value))
		return Runs.Report(Run, Report.Fenced, At, Fate.Fenced, Final)
	elseif Held == nil and Item == nil and Fence.Stamp <= Record.Horizon then
		return Runs.Report(Run, Report.Forgotten)
	end
	WriteFate(Run, Name, Book.Decision(Fence.Stamp, Fence.Print, Fate.Fenced, Fence.Attempt, Fence.Final))
	return Runs.Report(Run, Report.Fenced, Fence.Attempt, Fate.Fenced, Fence.Final)
end

return TxRules
