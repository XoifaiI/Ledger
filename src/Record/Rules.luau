--!strict
--!optimize 2

--[=[

	Rules: Logic. The rules of record 4, in the order Step tries them.

	Spec: record 4, step 4.

	A rule passes an op on or has the last word. The last word is a new fate, the fate the key
	holds, or a stop that leaves every later op undecided. The first op to reach the reducer runs
	the key's missing migrations. When they fail, every op judged is refused. A name held as a leg's
	fate, a decision or a work item is spent for an op. An op beside transaction marks is judged by
	the order rule of Marks, and a blocked op stops with the marks that block it. So does an op that
	would run a migration beside any mark.

	Return type: The ordered list of rules. The types are Run and Rule.
	Example usage:
		local RULES = require("./Rules")
--]=]

local Book = require("./Book")
local Diff = require("./Diff")
local Limits = require("../Core/Constants/Limits")
local Marks = require("./Marks")
local Migrate = require("./Migrate")
local Reduce = require("../Core/Reduce")
local Rooms = require("./Rooms")
local Types = require("./Types")

type Book = Book.Book
type Op = Types.Op

export type Run = {
	read Request: Types.Request,
	read Build: Types.Build,
	read Record: Book,
	read Entry: Book.Entry?,
	read Note: Types.Note,
	read Reducer: Reduce.Reducer<any, any>,
	read Clock: number,
	read Now: number?,
	read Epoch: number,
	State: { [string]: any },
	Folding: Reduce.Fold<any, any>?,
	Stop: Types.Why?,
	Fates: { [number]: number },
	FatesHeld: number,
	Minted: number,
	Newest: number,
	Last: number,
	Written: { [string]: true },
	UntimedBytes: number,
	Post: { Diff.Change }?,
	Given: { [string]: any }?,
	Sealed: Book.Seal?,
	Changed: boolean,
	Acted: boolean,
	Placed: string?,
}

export type Rule = (Run: Run, Index: number, Op: Op) -> boolean

local Fate = Book.Fate
local Form = Types.Form
local Why = Types.Why

local function Stop(Run: Run, Index: number, Reason: Types.Why): boolean
	Run.Note.Whys[Index] = Reason
	Run.Stop = Reason
	return true
end

local function Report(Run: Run, Index: number, Code: number): boolean
	Run.Note.Fates[Index] = Code
	return true
end

local function Keep(Run: Run, Name: string, Item: Book.Named, Untimed: boolean)
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
	Run.Newest = math.max(Run.Newest, Stamp)
	Run.Last = math.max(Run.Last, Op.Seq)
	if Op.Form == Form.Minted or Op.Form == Form.Hopeful then
		Run.Minted += 1
	elseif Op.Name then
		Keep(Run, Op.Name, { Kind = Op.Kind, Stamp = Stamp, Fate = Code, Print = Op.Print }, Untimed)
	end
	if Code ~= Fate.Took then
		Run.Fates[Op.Seq] = Code
		Run.FatesHeld += 1
		if Run.FatesHeld >= Limits.FATES_MAX then
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
	return Report(Run, Index, Entry.Fates[Op.Seq] or Fate.Took)
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
	return Report(Run, Index, Item.Fate)
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

local function Refuse(_: any, _: any): unknown
	return nil
end

local function Begin(Run: Run): Reduce.Fold<any, any>
	local Record, Build = Run.Record, Run.Build
	if Record.Level >= Build.Level then
		return Reduce.Start(Run.State, Run.Reducer)
	end
	local State = Migrate(Run.State, Record.Level, Build)
	if State == nil then
		return Reduce.Start(Run.State, Refuse)
	end
	Record.Level, Record.Floor = Build.Level, math.max(Record.Floor, Build.Floor)
	Run.State = State
	return Reduce.Start(State, Run.Reducer)
end

local function Judge(Run: Run, Index: number, Op: Op): boolean
	local Record = Run.Record
	local Standing = Marks.Standing(Record.Work)
	if Run.Folding == nil and Record.Level < Run.Build.Level and next(Standing) then
		return Blocked(Run, Index, Standing)
	end
	local Folding = Run.Folding or Begin(Run)
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
