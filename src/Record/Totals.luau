--!strict
--!optimize 2

--[=[

	Totals: Logic. A total's shards, and the pairs a server sums them from.

	Spec: extras 2.1 to 2.5 and 4. Model: Tot.tla.

	A total of S shards keeps shard i under the key $T:<name>:<S>:<i>. Each shard is a record whose
	state holds one Sum. Build gives the build every shard is judged with. Its reducer adds a bump to
	the sum, and refuses one that takes the sum past Max. Max is floor((2^53 - 1) / S). Home gives
	the shard a server's minted bumps go to, from its first server number. Named gives the shard a
	game's name goes to, the same for every server.

	A pair is a write count and the sum a shard held at it. Pair reads a pair from a value, and a
	shard no bump made reads as 0 at 0. Noted reads the pair a note's run landed or read. Merge keeps
	the pair with the larger write count, and never compares clocks. Sum adds the pairs once every
	shard has one.

	The summary item holds its bookkeeping as alphabet text in b: the format, the holder fields of
	extras 4 and every pair it holds. Summary merges a server's pairs into the item by write count,
	and names the server its holder until Until. It gives back nil while another holder is still
	ahead. Read gives the pairs an item holds, or Behind for an item of a newer format. Lapsed says
	whether the holder's lease is past.

	New makes what one server holds for a total of a store. It holds the place its shards are built
	under, its summary item and map, and its pairs. It also holds when it last had a full view, when
	it last read and tidied each shard, and whether it holds the item. Take merges a pair into it.
	Recent says whether it read every shard within an age. Untidy says whether a shard's value holds a
	writer entry or a timed name Windows.PRUNE_AGE old.

	Return type: A table with Key, Max, Build, Home, Named, Pair, Noted, Merge, Sum, Summary, Read,
	Lapsed, Map, New, Take, Recent, Untidy, PREFIX and FORMAT. The types are Pair, Pairs and Held.
	Example usage:
		local Pairs = Totals.Merge(Held, Totals.Pair(Value))
--]=]

local Hash = require("../Encode/Hash")
local Key = require("./Key")
local Limits = require("../Core/Constants/Limits")
local Reader = require("../Encode/Reader")
local Sizes = require("../Core/Constants/Sizes")
local Types = require("./Types")
local Windows = require("../Core/Constants/Windows")
local Writer = require("../Encode/Writer")

export type Pair = {
	read Writes: number,
	read Sum: number,
}

export type Pairs = { [number]: Pair }

type Summary = {
	read Holder: number,
	read Until: number,
	read At: number,
	read Pairs: Pairs,
}

export type Held = {
	read Name: string,
	read Shards: number,
	read Place: string,
	read Item: string,
	read Map: string,
	Pairs: Pairs,
	Seen: number?,
	Read: { [number]: number },
	Tidied: { [number]: number },
	Holding: boolean,
	Called: number,
}

local PREFIX = "$T:"
local FORMAT = 1
local MAPS = Limits.MAPS

local Totals = {}

function Totals.Key(Name: string, Shards: number, Index: number): string
	return `{PREFIX}{Name}:{Shards}:{Index}`
end

function Totals.Max(Shards: number): number
	return (Limits.MONEY_LIMIT - 1) // Shards
end

function Totals.Build(Shards: number, Base: Types.Build): Types.Build
	local Max = Totals.Max(Shards)
	local function Reducer(State: { Sum: number }, Op: { Add: number }): unknown
		local Next = State.Sum + Op.Add
		if math.abs(Next) > Max then
			return nil
		end
		return { Sum = Next }
	end
	local Made = table.clone(Base) :: any
	Made.Reducer, Made.Migrations, Made.Default = Reducer, {}, { Sum = 0 }
	Made.Level, Made.Floor, Made.Money, Made.Fields = 0, 0, {}, { Sum = true }
	Made.Window, Made.Erasable, Made.UntimedRoom = {}, false, Sizes.UNTIMED_ROOM_MIN
	Made.LegLimit, Made.Paced = Limits.LEGS_MIN, Limits.PACE_SHARD
	return Made :: Types.Build
end

function Totals.Home(Name: string, Number: number, Shards: number): number
	return Hash(Name, Number) % Shards
end

function Totals.Named(Once: string, Shards: number): number
	return Hash(Once) % Shards
end

function Totals.Pair(Value: unknown): Pair?
	local Found = Key.Read(Value)
	if Found == nil then
		return { Writes = 0, Sum = 0 }
	elseif type(Found) ~= "table" or type(Found.State.Sum) ~= "number" then
		return nil
	end
	return { Writes = Found.Book.Writes, Sum = Found.State.Sum }
end

function Totals.Noted(Note: Types.Note): Pair?
	local State = Note.State :: any
	if type(State) ~= "table" or type(State.Sum) ~= "number" then
		return nil
	end
	return { Writes = Note.Writes, Sum = State.Sum }
end

function Totals.Merge(Held: Pair?, Fresh: Pair?): Pair?
	if Held == nil or (Fresh and Fresh.Writes > Held.Writes) then
		return Fresh
	end
	return Held
end

function Totals.Sum(Pairs: Pairs, Shards: number): number?
	local Sum = 0
	for Index = 0, Shards - 1 do
		local Held = Pairs[Index]
		if Held == nil then
			return nil
		end
		Sum += Held.Sum
	end
	return Sum
end

local function Decode(Text: string): Summary | "Behind"
	local Book = Reader.New(Text)
	if Reader.Var(Book) > FORMAT then
		return "Behind"
	end
	local Holder, Until, At = Reader.Var(Book), Reader.Var(Book), Reader.Var(Book)
	local Pairs: Pairs = {}
	for _ = 1, Reader.Var(Book) do
		local Index, Writes = Reader.Var(Book), Reader.Var(Book)
		Pairs[Index] = { Writes = Writes, Sum = Reader.Signed(Book) }
	end
	if not Reader.Done(Book) then
		error("Totals: a broken summary")
	end
	return { Holder = Holder, Until = Until, At = At, Pairs = Pairs }
end

local function Opened(Current: unknown): Summary | "Behind" | nil
	local Item = if type(Current) == "table" then Current :: any else nil
	if Item == nil or type(Item.b) ~= "string" then
		return nil
	end
	local Ok, Found = pcall(Decode, Item.b)
	return if Ok then Found else nil
end

function Totals.Read(Current: unknown, Shards: number): Pairs | "Behind" | nil
	local Found = Opened(Current)
	if type(Found) ~= "table" then
		return Found
	end
	local Pairs: Pairs = {}
	for Index = 0, Shards - 1 do
		Pairs[Index] = Found.Pairs[Index]
	end
	return Pairs
end

function Totals.Summary(Current: unknown, Pairs: Pairs, Shards: number, Server: number, Now: number, Until: number): unknown
	local Found = Opened(Current)
	if Found == "Behind" or (Found and Found.Holder ~= Server and Found.Until > Now) then
		return nil
	end
	local Kept: { [number]: Pair } = {}
	local Count = 0
	for Index = 0, Shards - 1 do
		local Pair = Totals.Merge(if Found then Found.Pairs[Index] else nil, Pairs[Index])
		if Pair then
			Kept[Index], Count = Pair, Count + 1
		end
	end
	local Book = Writer.New()
	for _, Number in { FORMAT, Server, Until, Now, Count } do
		Writer.Var(Book, Number)
	end
	for Index = 0, Shards - 1 do
		local Pair = Kept[Index]
		if Pair then
			Writer.Var(Book, Index)
			Writer.Var(Book, Pair.Writes)
			Writer.Signed(Book, Pair.Sum)
		end
	end
	return { b = Writer.Finish(Book) }
end

function Totals.Lapsed(Current: unknown, Now: number, Slack: number): boolean
	local Found = Opened(Current)
	return type(Found) ~= "table" or Now > Found.Until + Slack
end

function Totals.Map(Name: string): string
	return `Ledger_Total_{Hash(Name) % MAPS}`
end

function Totals.New(Store: string, Name: string, Shards: number): Held
	local Item = `t/{Store}/{Name}:{Shards}`
	return {
		Name = Name,
		Shards = Shards,
		Place = `{Store}{PREFIX}{Name}:{Shards}`,
		Item = Item,
		Map = Totals.Map(Item),
		Pairs = {},
		Read = {},
		Tidied = {},
		Holding = false,
		Called = 0,
	}
end

function Totals.Take(Held: Held, Index: number, Fresh: Pair?)
	Held.Pairs[Index] = Totals.Merge(Held.Pairs[Index], Fresh)
end

function Totals.Recent(Held: Held, Now: number, Age: number): boolean
	for Index = 0, Held.Shards - 1 do
		local At = Held.Read[Index]
		if At == nil or Now - At > Age then
			return false
		end
	end
	return true
end

function Totals.Untidy(Value: unknown, Now: number): boolean
	local Found = Key.Read(Value)
	if type(Found) ~= "table" then
		return false
	end
	for _, Entry in Found.Book.Writers do
		if Now - Entry.Stamp >= Windows.PRUNE_AGE then
			return true
		end
	end
	for _, Item in Found.Book.Timed do
		if Now - Item.Stamp >= Windows.PRUNE_AGE then
			return true
		end
	end
	return false
end

Totals.PREFIX = PREFIX
Totals.FORMAT = FORMAT

return Totals
