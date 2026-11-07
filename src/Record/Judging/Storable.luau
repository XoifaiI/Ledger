--!strict
--!optimize 2

--[=[
	Storable: the rules of a storable value, each written once as a check that gives a Failure, and the full walk
	and the freeze that apply them. StorableChange applies the same rules to only what a new table changed.

	A value past Record.StorableDepthMax is not storable. DeepFreeze vets a table only after freezing it itself, so
	what it checked cannot change; a table the game froze is never vetted.

	Return type: A table with Check, DeepFreeze, TextOf, PathText, VisitTable, IsCovered, Fits, RootLevel, the failure
	checks DepthFailure, ScalarFailure, MetatableFailure, TableFailure, KeyFailure, KindFailure and GapFailure, and the
	Tree, Search and Failure types.
	Example usage:
		local Problem = Storable.Check(State, "the state") --> nil, or "the state.Gold is NaN or infinity ..."
		Storable.DeepFreeze(State)
--]=]

local Record = require("../Constants/Record")
local Vetted = require("../Encoding/Vetted")

export type Tree = { [unknown]: unknown }

export type Search = {
	Keys: { unknown },
	Seen: { [unknown]: boolean },
}

export type Failure = {
	Problem: string,
	Level: number,
}

local StorableNotFinite = "is NaN or infinity, which cannot be stored"
local StorableBadUtf8 = "is a string that is not valid UTF-8"
local StorableKeyBadUtf8 = "has a key that is not valid UTF-8"
local StorableMetatable = "has a metatable, and a stored table has none"
local StorableCycle = "contains itself, and a stored value is a tree"
local StorableMixedKeys = "has array keys and string keys together, and it must have only one kind"
local StorableGap = "has number keys that are not 1 up to its length, so it is not an array without gaps"
local StorableTooDeep = `is nested deeper than {Record.StorableDepthMax} levels`

local RootLevel = 1

local DepthMax = Record.StorableDepthMax

local function StorableType(TypeName: string): string
	return `is a {TypeName}, and only booleans, numbers, strings and tables can be stored`
end

local function StorableKeyType(TypeName: string): string
	return `has a key that is a {TypeName}, and a key must be a string or a place in an array`
end

local function Unstorable(Where: string, Path: string, Problem: string): string
	return `{Where}{Path} {Problem}`
end

local function PathText(Keys: { unknown }, Level: number): string
	local Parts: { string } = {}
	for Index = 2, Level do
		local Key = Keys[Index]
		if type(Key) == "number" then
			table.insert(Parts, `[{Key}]`)
		else
			table.insert(Parts, `.{Key}`)
		end
	end
	return table.concat(Parts)
end

local function Fail(Problem: string, Level: number): Failure
	return { Problem = Problem, Level = Level }
end

local function Fits(Level: number, Height: number): boolean
	return Level + Height <= DepthMax
end

local function IsCovered(Held: Tree, Level: number): boolean
	local Height = Vetted.HeightOf(Held)
	return Height ~= nil and Fits(Level, Height)
end

local function DepthFailure(Level: number): Failure?
	if Level > DepthMax then
		return Fail(StorableTooDeep, Level)
	end
	return nil
end

local function ScalarFailure(Value: unknown, Level: number): Failure?
	if type(Value) == "boolean" then
		return nil
	end
	if type(Value) == "number" then
		if Value ~= Value or Value == math.huge or Value == -math.huge then
			return Fail(StorableNotFinite, Level)
		end
		return nil
	end
	if type(Value) == "string" then
		if utf8.len(Value) == nil then
			return Fail(StorableBadUtf8, Level)
		end
		return nil
	end
	return Fail(StorableType(typeof(Value)), Level)
end

local function MetatableFailure(Held: Tree, Level: number): Failure?
	if getmetatable(Held) ~= nil then
		return Fail(StorableMetatable, Level)
	end
	return nil
end

local function TableFailure(Search: Search, Held: Tree, Level: number): Failure?
	local Metatable = MetatableFailure(Held, Level)
	if Metatable ~= nil then
		return Metatable
	end
	if Search.Seen[Held] then
		return Fail(StorableCycle, Level)
	end
	return nil
end

local function KeyFailure(Key: unknown, Level: number): Failure?
	if type(Key) == "number" then
		return nil
	end
	if type(Key) ~= "string" then
		return Fail(StorableKeyType(typeof(Key)), Level)
	end
	if utf8.len(Key) == nil then
		return Fail(StorableKeyBadUtf8, Level)
	end
	return nil
end

local function KindFailure(Numbers: number, Strings: number, Level: number): Failure?
	if Numbers > 0 and Strings > 0 then
		return Fail(StorableMixedKeys, Level)
	end
	return nil
end

local function GapFailure(Held: Tree, Numbers: number, Level: number): Failure?
	for Index = 1, Numbers do
		if Held[Index] == nil then
			return Fail(StorableGap, Level)
		end
	end
	return nil
end

local Visit: (Search: Search, Value: unknown, Level: number) -> Failure?

local function VisitKeys(Held: Tree, Level: number): Failure?
	local Numbers = 0
	local Strings = 0
	for Key in Held do
		local Failure = KeyFailure(Key, Level)
		if Failure ~= nil then
			return Failure
		end
		if type(Key) == "number" then
			Numbers += 1
		else
			Strings += 1
		end
	end

	local Mixed = KindFailure(Numbers, Strings, Level)
	if Mixed ~= nil then
		return Mixed
	end
	return GapFailure(Held, Numbers, Level)
end

local function VisitTable(Search: Search, Held: Tree, Level: number): Failure?
	if IsCovered(Held, Level) then
		return nil
	end
	local Entry = TableFailure(Search, Held, Level)
	if Entry ~= nil then
		return Entry
	end
	local Keys = VisitKeys(Held, Level)
	if Keys ~= nil then
		return Keys
	end

	Search.Seen[Held] = true
	for Key, Inner in Held do
		Search.Keys[Level + 1] = Key
		local InnerFailure = Visit(Search, Inner, Level + 1)
		if InnerFailure ~= nil then
			return InnerFailure
		end
	end
	Search.Seen[Held] = nil
	return nil
end

function Visit(Search: Search, Value: unknown, Level: number): Failure?
	local TooDeep = DepthFailure(Level)
	if TooDeep ~= nil then
		return TooDeep
	end
	if type(Value) == "table" then
		return VisitTable(Search, Value :: Tree, Level)
	end
	return ScalarFailure(Value, Level)
end

local function HeightBelow(Inner: unknown): number?
	if type(Inner) == "table" then
		return Vetted.HeightOf(Inner :: Tree)
	end
	if ScalarFailure(Inner, RootLevel) ~= nil then
		return nil
	end
	return 0
end

local function VetFrozen(Held: Tree): ()
	if MetatableFailure(Held, RootLevel) ~= nil then
		return
	end
	if VisitKeys(Held, RootLevel) ~= nil then
		return
	end

	local Height = 0
	local Count = 0
	for _, Inner in Held do
		local Below = HeightBelow(Inner)
		if Below == nil then
			return
		end
		Count += 1
		Height = math.max(Height, Below + 1)
	end
	if Fits(RootLevel, Height) then
		Vetted.Add(Held, Height, Count)
	end
end

local function Freeze(Value: unknown, Seen: { [unknown]: boolean }): ()
	if type(Value) ~= "table" or Seen[Value] then
		return
	end
	Seen[Value] = true

	local Held = Value :: Tree
	if Vetted.IsVetted(Held) then
		return
	end
	for _, Inner in Held do
		Freeze(Inner, Seen)
	end
	if table.isfrozen(Held) then
		return
	end
	table.freeze(Held)
	VetFrozen(Held)
end

local function TextOf(Search: Search, Failure: Failure, Where: string): string
	return Unstorable(Where, PathText(Search.Keys, Failure.Level), Failure.Problem)
end

local function Check(Value: unknown, Where: string): string?
	local Search: Search = { Keys = {}, Seen = {} }
	local Failure = Visit(Search, Value, RootLevel)
	if Failure == nil then
		return nil
	end
	return TextOf(Search, Failure, Where)
end

local function DeepFreeze(Value: unknown): ()
	Freeze(Value, {})
end

return {
	Check = Check,
	DeepFreeze = DeepFreeze,
	TextOf = TextOf,
	PathText = PathText,
	VisitTable = VisitTable,
	IsCovered = IsCovered,
	Fits = Fits,
	DepthFailure = DepthFailure,
	ScalarFailure = ScalarFailure,
	MetatableFailure = MetatableFailure,
	TableFailure = TableFailure,
	KeyFailure = KeyFailure,
	KindFailure = KindFailure,
	GapFailure = GapFailure,
	RootLevel = RootLevel,
}
