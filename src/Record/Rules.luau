--!strict
--!optimize 2

--[=[
	Rules: Logic. The rules each op of a request meets, in the order of record 4 step 4.

	Spec: record 4, step 4.

	A rule passes an op on or has the last word: a new fate, the fate the key holds, or a stop that
	leaves this op and every later one undecided, so the ops a run decides are always a prefix. The
	first op that reaches the reducer runs the key's missing migrations, and when they fail every op
	judged after is refused. A name held as a leg's fate, a decision or a work item is spent for an
	op. An op beside transaction marks is judged by the order rule of Marks, and one that would run a
	migration beside any mark is blocked.

	Return type: The ordered list of rules, and the Rule type.
	Example usage:
		local RULES = require("./Rules")
--]=]

local Book = require("./Book")
local Marks = require("./Marks")
local Migrate = require("./Migrate")
local Reduce = require("../Core/Reduce")
local Requests = require("./Requests")
local Rooms = require("./Rooms")
local Runs = require("./Runs")
local Types = require("./Types")

type Book = Book.Book
type Op = Requests.Op

type Run = Runs.Run

export type Rule = (Run: Run, Index: number, Op: Op) -> boolean

local FATES_MAX = 64

local Fate = Book.Fate
local Form = Requests.Form
local Why = Types.Why

local function Stop(Run: Run, Index: number, Reason: Types.Why): boolean
	Run.Note.Whys[Index] = Reason
	Run.Stop = Reason
	return true
end

local function ReportFate(Run: Run, Index: number, Code: number): boolean
	Run.Note.Fates[Index] = Code
	return true
end

local function KeepName(Run: Run, Name: string, Item: Book.Named, Untimed: boolean)
	Run.Written[Name] = true
	if Untimed and Item.Fate == Fate.Took then
		Run.Record.Untimed[Name] = Item
		Run.UntimedBytes += Book.NamedWidth(Name, Item, Run.Epoch)
	else
		Run.Record.Timed[Name] = Item
	end
end

local function Decide(Run: Run, Index: number, Op: Op, Code: number): boolean
	local Untimed = Op.Form == Form.Untimed
	local Stamp = if Untimed then Run.Clock else Op.Stamp
	Run.Note.Fates[Index] = Code
	table.insert(Run.Note.Decided, Op.Seq)
	local Newest = Run.Newest
	Run.Newest = if Newest then math.max(Newest, Stamp) else Stamp
	Run.Last = math.max(Run.Last, Op.Seq)
	if Op.Form == Form.Minted or Op.Form == Form.Hopeful then
		Run.Minted += 1
	elseif Op.Name then
		KeepName(Run, Op.Name, { Kind = Op.Kind, Stamp = Stamp, Fate = Code, Print = Op.Print }, Untimed)
	end
	if Code ~= Fate.Took then
		Run.Fates[Op.Seq] = Code
		Run.FatesHeld += 1
		if Run.FatesHeld >= FATES_MAX then
			Run.Stop = Why.Undecided
		end
	end
	return true
end

local function Prefix(Run: Run, Index: number, _: Op): boolean
	if Run.Stop == nil then
		return false
	end
	Run.Note.Whys[Index] = Why.Undecided
	return true
end

local function Incarnation(Run: Run, Index: number, Op: Op): boolean
	local Id = Op.Create or Op.Id
	if Id == nil or Id == Run.Record.Id then
		return false
	end
	return Stop(Run, Index, Why.Missing)
end

local function DecidedBefore(Run: Run, Index: number, Op: Op): boolean
	local Entry = Run.Entry
	if Entry == nil or Op.Seq > Entry.Lo then
		return false
	end
	return ReportFate(Run, Index, Entry.Fates[Op.Seq] or Fate.Took)
end

local function NameHeld(Run: Run, Index: number, Op: Op): boolean
	local Name = Op.Name
	if Name == nil then
		return false
	end
	local Item = Run.Record:Held(Name)
	local Working = Run.Record.Work[Name] ~= nil
	if Item == nil and not Working then
		return false
	elseif Item == nil or Working or Item.Role ~= nil or Item.Print ~= Op.Print then
		Run.Note.Whys[Index] = Why.Spent
		return true
	end
	return ReportFate(Run, Index, Item.Fate)
end

local function Forgotten(Run: Run, Index: number, Op: Op): boolean
	local Unnamed = Op.Form == Form.Minted or Op.Form == Form.Hopeful
	local Covered = Op.Form == Form.Timed or (Unnamed and Run.Entry == nil)
	if Covered and Op.Stamp <= Run.Record.Horizon then
		return Stop(Run, Index, Why.Forgotten)
	end
	return false
end

local function Floor(Run: Run, Index: number, _: Op): boolean
	if Run.Record.Floor > Run.Build.Floor then
		return Stop(Run, Index, Why.Behind)
	end
	return false
end

local function Ahead(Run: Run, Index: number, Op: Op): boolean
	if Op.Form == Form.Untimed then
		return if Run.Now == nil then Stop(Run, Index, Why.Undecided) else false
	elseif Op.Stamp > math.max(Run.Clock, Run.Record.Horizon) + Run.Build.Ahead then
		return Stop(Run, Index, Why.Ahead)
	end
	return false
end

local function Turned(Run: Run, Index: number, Op: Op): boolean
	if Op.Form == Form.Hopeful and Op.View ~= Run.Record.Cuts then
		return Decide(Run, Index, Op, Fate.Turned)
	end
	return false
end

local function Room(Run: Run, Index: number, Op: Op): boolean
	if Op.Form ~= Form.Untimed then
		return false
	end
	local Item: Book.Named = { Kind = Op.Kind, Stamp = Run.Clock, Fate = Fate.Took, Print = Op.Print }
	local Over = Run.UntimedBytes + Book.NamedWidth(Op.Name :: string, Item, Run.Epoch) - Run.Build.UntimedRoom
	if Over > 0 and Run.Now then
		local Freed = Rooms.Evict(Run.Record, Run.Build, Run.Now, Run.Epoch, Over)
		Run.UntimedBytes -= Freed
		Over -= Freed
	end
	return if Over > 0 then Stop(Run, Index, Why.NoRoom) else false
end

local function Blocked(Run: Run, Index: number, Items: { [string]: Book.Work }): boolean
	Run.Note.Items = Items
	return Stop(Run, Index, Why.Blocked)
end

local function RefuseEvery(_: any, _: any): unknown
	return nil
end

local function StartFold(Run: Run): Reduce.Fold<any, any>
	local Record, Build = Run.Record, Run.Build
	if Record.Level >= Build.Level then
		return Reduce.Start(Run.State, Run.Reducer)
	end
	local State = Migrate(Run.State, Record.Level, Build)
	if State == nil then
		return Reduce.Start(Run.State, RefuseEvery)
	end
	Record.Level = Build.Level
	Record.Floor = math.max(Record.Floor, Build.Floor)
	Run.State = State
	return Reduce.Start(State, Run.Reducer)
end

local function Judge(Run: Run, Index: number, Op: Op): boolean
	local Record = Run.Record
	local Standing = Book.Marks(Record.Work)
	if Run.Folding == nil and Record.Level < Run.Build.Level and next(Standing) then
		return Blocked(Run, Index, Standing)
	end
	local Folding = Run.Folding or StartFold(Run)
	Run.Folding = Folding
	local Blockers = Marks.Order(Record.Work, Run.Build, Run.Reducer, Folding.State, Op.Body)
	if Blockers then
		return Blocked(Run, Index, Blockers)
	end
	local Took, Reason = Reduce.Apply(Folding, Op.Body)
	Run.Changed = Run.Changed or Took
	return Decide(Run, Index, Op, if Took then Fate.Took elseif Reason == Fate.Full then Fate.Full else Fate.Refused)
end

return {
	Prefix,
	Incarnation,
	DecidedBefore,
	NameHeld,
	Forgotten,
	Floor,
	Ahead,
	Turned,
	Room,
	Judge,
} :: { Rule }
