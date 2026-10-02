--!strict
--!optimize 2

--[=[
	Shards: Logic. The keys a total or a split quantity is spread over, and the pairs a server sums
	them from.

	Spec: extras 2.1 to 2.5 and 4; hot keys 2.8 and 2.9. Model: Tot.tla.

	A total of S shards keeps shard i under $T:<name>:<S>:<i>, a record whose state is one Sum. A
	shard refuses a bump that would pass floor((2^53 - 1) / S), so the sum of every shard stays exact.
	A server's minted bumps go to its home shard, and a named bump goes to the shard its name hashes
	to, the same on every server. A pair is a write count and the values its key held at that count.
	Pairs merge by the larger write count and never by a clock, and a sum is given only once every
	key has a pair. The summary item in MemoryStore holds pairs and the holder fields of extras 4, and
	is advice. A kind says how one family of keys is named and measured: SUM for a total, and
	Parts.KIND for a split quantity.

	Return type: A table of the shard functions and constants, and the Kind, Pair, Pairs and Held
	types.
	Example usage:
		local Pairs = Shards.Merge(Held, Shards.Pair(Value, Kind))
--]=]

local Hash = require("../Encode/Hash")
local Key = require("./Key")
local Limits = require("../Core/Constants/Limits")
local Reader = require("../Encode/Reader")
local Sizes = require("../Core/Constants/Sizes")
local Types = require("./Types")
local Windows = require("../Core/Constants/Windows")
local Writer = require("../Encode/Writer")

export type Kind = {
	read Prefix: string,
	read Width: number,
	read Measure: (State: any) -> { number }?,
}

export type Pair = {
	read Writes: number,
	read Values: { number },
}

export type Pairs = { [number]: Pair }

type Summary = {
	read Holder: number,
	read Until: number,
	read At: number,
	read Width: number,
	read Pairs: Pairs,
}

export type Held = {
	read Name: string,
	read Shards: number,
	read Kind: Kind,
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
local SHARDS = 16
local SHARDS_MAX = 64
local TOTAL_NAME = 37
local PACE_SHARD = 2
local PRUNE_AGE = 86400
local SUMMARY = 3600
local DOWN = 60
local HOLDING = 600
local MAX_AGE = 60

assert(PRUNE_AGE >= Windows.MINTED + 2 * Windows.SIGMA and PRUNE_AGE <= Windows.CEILING - 2 * Windows.SIGMA, "Shards: PRUNE_AGE must lie from MINTED + 2 * SIGMA to CEILING - 2 * SIGMA (extras 12)")

local SUM: Kind = {
	Prefix = PREFIX,
	Width = 1,
	Measure = function(State: any): { number }?
		return if type(State.Sum) == "number" then { State.Sum } else nil
	end,
}

local Shards = {
	SUM = SUM,
	PREFIX = PREFIX,
	FORMAT = FORMAT,
	SHARDS = SHARDS,
	SHARDS_MAX = SHARDS_MAX,
	TOTAL_NAME = TOTAL_NAME,
	PRUNE_AGE = PRUNE_AGE,
	SUMMARY = SUMMARY,
	DOWN = DOWN,
	HOLDING = HOLDING,
	MAX_AGE = MAX_AGE,
}

function Shards.Key(Name: string, Count: number, Index: number, Prefix: string?): string
	return `{Prefix or PREFIX}{Name}:{Count}:{Index}`
end

function Shards.Max(Count: number): number
	return (Limits.MONEY_LIMIT - 1) // Count
end

function Shards.Build(Count: number, Base: Types.Build): Types.Build
	local Max = Shards.Max(Count)
	local function Reducer(State: { Sum: number }, Op: { Add: number }): unknown
		local Next = State.Sum + Op.Add
		if math.abs(Next) > Max then
			return nil
		end
		return { Sum = Next }
	end
	local Made = table.clone(Base) :: any
	Made.Reducer = Reducer
	Made.Migrations = {}
	Made.Default = { Sum = 0 }
	Made.Level = 0
	Made.Floor = 0
	Made.Money = {}
	Made.Fields = { Sum = true }
	Made.Window = {}
	Made.Erasable = false
	Made.UntimedRoom = Sizes.UNTIMED_ROOM_MIN
	Made.LegLimit = Limits.LEGS_MIN
	Made.Paced = PACE_SHARD
	return Made :: Types.Build
end

function Shards.Home(Name: string, Number: number, Count: number): number
	return Hash(Name, Number) % Count
end

function Shards.Named(Once: string, Count: number): number
	return Hash(Once) % Count
end

function Shards.Pair(Value: unknown, Kind: Kind): Pair?
	local Found = Key.Read(Value)
	if Found == nil then
		return { Writes = 0, Values = table.create(Kind.Width, 0) }
	elseif type(Found) ~= "table" then
		return nil
	end
	local Values = Kind.Measure(Found.State)
	return if Values then { Writes = Found.Book.Writes, Values = Values } else nil
end

function Shards.Noted(Note: Types.Note, Kind: Kind): Pair?
	local State = Note.State
	local Values = if type(State) == "table" then Kind.Measure(State) else nil
	return if Values then { Writes = Note.Writes, Values = Values } else nil
end

function Shards.Merge(Held: Pair?, Fresh: Pair?): Pair?
	if Held == nil or (Fresh and Fresh.Writes > Held.Writes) then
		return Fresh
	end
	return Held
end

function Shards.Sum(Pairs: Pairs, Count: number, Width: number): { number }?
	local Sum = table.create(Width, 0)
	for Index = 0, Count - 1 do
		local Held = Pairs[Index]
		if Held == nil then
			return nil
		end
		for Slot = 1, Width do
			Sum[Slot] += Held.Values[Slot] or 0
		end
	end
	return Sum
end

local function Decode(Text: string): Summary | "Behind"
	local Book = Reader.New(Text)
	if Reader.Var(Book) > FORMAT then
		return "Behind"
	end
	local Holder, Until, At, Width = Reader.Var(Book), Reader.Var(Book), Reader.Var(Book), Reader.Var(Book)
	local Pairs: Pairs = {}
	for _ = 1, Reader.Var(Book) do
		local Index, Writes = Reader.Var(Book), Reader.Var(Book)
		local Values: { number } = {}
		for Slot = 1, Width do
			Values[Slot] = Reader.Signed(Book)
		end
		Pairs[Index] = { Writes = Writes, Values = Values }
	end
	if not Reader.Done(Book) then
		error("Shards: a broken summary")
	end
	return { Holder = Holder, Until = Until, At = At, Width = Width, Pairs = Pairs }
end

local function Opened(Current: unknown): Summary | "Behind" | nil
	local Item = if type(Current) == "table" then Current :: any else nil
	if Item == nil or type(Item.b) ~= "string" then
		return nil
	end
	local Ok, Found = pcall(Decode, Item.b)
	return if Ok then Found else nil
end

function Shards.Read(Current: unknown, Count: number, Width: number): Pairs | "Behind" | nil
	local Found = Opened(Current)
	if type(Found) ~= "table" then
		return Found
	elseif Found.Width ~= Width then
		return nil
	end
	local Pairs: Pairs = {}
	for Index = 0, Count - 1 do
		Pairs[Index] = Found.Pairs[Index]
	end
	return Pairs
end

function Shards.Summary(Current: unknown, Pairs: Pairs, Count: number, Width: number, Server: number, Now: number, Until: number): unknown
	local Found = Opened(Current)
	if Found == "Behind" or (Found and Found.Holder ~= Server and Found.Until > Now) then
		return nil
	end
	local Same = Found and Found.Width == Width
	local Kept: { [number]: Pair } = {}
	local Filled = 0
	for Index = 0, Count - 1 do
		local Pair = Shards.Merge(if Found and Same then Found.Pairs[Index] else nil, Pairs[Index])
		if Pair then
			Kept[Index] = Pair
			Filled += 1
		end
	end
	local Book = Writer.New()
	for _, Number in { FORMAT, Server, Until, Now, Width, Filled } do
		Writer.Var(Book, Number)
	end
	for Index = 0, Count - 1 do
		local Pair = Kept[Index]
		if Pair then
			Writer.Var(Book, Index)
			Writer.Var(Book, Pair.Writes)
			for Slot = 1, Width do
				Writer.Signed(Book, Pair.Values[Slot] or 0)
			end
		end
	end
	return { b = Writer.Finish(Book) }
end

function Shards.Lapsed(Current: unknown, Now: number, Slack: number): boolean
	local Found = Opened(Current)
	return type(Found) ~= "table" or Now > Found.Until + Slack
end

function Shards.Map(Name: string): string
	return `Ledger_Total_{Hash(Name) % MAPS}`
end

function Shards.New(Store: string, Name: string, Count: number, Kind: Kind?): Held
	local Using = Kind or SUM
	local Place = `{Store}{Using.Prefix}{Name}:{Count}`
	local Item = `t/{Place}`
	return {
		Name = Name,
		Shards = Count,
		Kind = Using,
		Place = Place,
		Item = Item,
		Map = Shards.Map(Item),
		Pairs = {},
		Read = {},
		Tidied = {},
		Holding = false,
		Called = 0,
	}
end

function Shards.Take(Held: Held, Index: number, Fresh: Pair?)
	Held.Pairs[Index] = Shards.Merge(Held.Pairs[Index], Fresh)
end

function Shards.Recent(Held: Held, Now: number, Age: number): boolean
	for Index = 0, Held.Shards - 1 do
		local At = Held.Read[Index]
		if At == nil or Now - At > Age then
			return false
		end
	end
	return true
end

function Shards.Untidy(Value: unknown, Now: number): boolean
	local Found = Key.Read(Value)
	if type(Found) ~= "table" then
		return false
	end
	for _, Entry in Found.Book.Writers do
		if Now - Entry.Stamp >= PRUNE_AGE then
			return true
		end
	end
	for _, Item in Found.Book.Timed do
		if Now - Item.Stamp >= PRUNE_AGE then
			return true
		end
	end
	return false
end

function Shards.TakeRead(Held: Held, Index: number, Value: unknown, Now: number)
	Shards.Take(Held, Index, Shards.Pair(Value, Held.Kind))
	Held.Read[Index] = Now
end

function Shards.StartTidy(Held: Held, Index: number, Value: unknown, Now: number): boolean
	local Tidied = Held.Tidied[Index]
	if not Shards.Untidy(Value, Now) or (Tidied ~= nil and Now - Tidied < PRUNE_AGE) then
		return false
	end
	Held.Tidied[Index] = Now
	return true
end

function Shards.NoteCall(Held: Held, Now: number)
	Held.Called = Now
end

function Shards.NoteFullView(Held: Held, Now: number)
	Held.Seen = Now
end

function Shards.StartHolding(Held: Held): boolean
	if Held.Holding then
		return false
	end
	Held.Holding = true
	return true
end

function Shards.StopHolding(Held: Held)
	Held.Holding = false
end

return Shards
