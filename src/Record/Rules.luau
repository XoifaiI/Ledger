--!strict
--!optimize 2

--[=[

	Rules: The rules of record 4 that judge one op, in the order Step tries them.

	Each rule looks at one op of a run and either passes it on or has the last word: it decides a new
	fate, reports the fate the key already holds, or stops the op, which leaves every later op of the
	request undecided. In order: an earlier op stopped, the op was judged for another incarnation, its
	writer decided it before, its name is held, it is under the horizon, the key is past this build's
	floor, it is stamped too far ahead or needs a clock that is not good, it is a hopeful op judged
	before a cut, an untimed name has no room, and last the game's reducer judges it.

	Return type: The ordered list of rules. The types are Run and Rule.
	Example usage:
		local RULES = require("./Rules")
		for _, Rule in RULES do
			if Rule(Run, Index, Op) then
				break
			end
		end
--]=]

local Book = require("./Book")
local Limits = require("../Core/Constants/Limits")
local Reduce = require("../Core/Reduce")
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
}

export type Rule = (Run: Run, Index: number, Op: Op) -> boolean

local Fate = Book.Fate
local Form = Types.Form
local Why = Types.Why

local function Held(Record: Book, Name: string): Book.Named?
	return Record.Timed[Name] or Record.Untimed[Name] or Record.Cut[Name]
end

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
	local Item = if Name then Held(Run.Record, Name) else nil
	if Item == nil then
		return false
	elseif Item.Print ~= Op.Print then
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
	if Run.UntimedBytes + Book.NamedWidth(Op.Name :: string, Item, Run.Epoch) <= Run.Build.UntimedRoom then
		return false
	end
	return Stop(Run, Index, Why.NoRoom)
end

local function Judge(Run: Run, Index: number, Op: Op): boolean
	local Folding = Run.Folding or Reduce.Start(Run.State, Run.Reducer)
	Run.Folding = Folding
	local Took, Reason = Reduce.Apply(Folding, Op.Body)
	return Decide(Run, Index, Op, if Took then Fate.Took elseif Reason == Fate.Full then Fate.Full else Fate.Refused)
end

local RULES: { Rule } = { Prefix, Incarnation, DecidedBefore, NameHeld, Forgotten, Floor, Ahead, Turned, Room, Judge }

return table.freeze(RULES)
