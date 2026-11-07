--!strict
--!optimize 2

--[=[
	StorableChange: the storable check of a state a reducer returned, made against the vetted table it came from so
	that only what changed is walked. It applies Storable's rules and gives the problem Storable's full walk gives,
	with the same path.

	A value equal to one of a vetted table's values is that same checked value. The old table is trusted only when
	it is vetted, never the reducer's input, which the reducer may change during its run unless it was vetted before.
	The check freezes nothing: it records each table's height, key count and JSON size in NewTables, and VetMade
	vets those tables once the whole result has passed.

	Return type: A table with Check, VetMade, VetSubsetOf and TrustedOld, and the NewTables type.
	Example usage:
		local NewTables: StorableChange.NewTables = {}
		local Problem = StorableChange.Check(Result, Old, "the state", NewTables)
		if Problem == nil then StorableChange.VetMade(NewTables) end
--]=]

local Json = require("../Encoding/Json")
local Storable = require("./Storable")
local Vetted = require("../Encoding/Vetted")

type Failure = Storable.Failure
type Search = Storable.Search
type Tree = Storable.Tree

type Facts = {
	Height: number?,
	Bytes: number,
	Count: number,
}

export type NewTables = { [Tree]: Facts }

local RootLevel = Storable.RootLevel

local function ChangedKeys(New: Tree, Old: Tree): ({ unknown }, number)
	local Changed: { unknown } = {}
	local Count = 0
	for Key, Inner in New do
		Count += 1
		if Old[Key] ~= Inner then
			table.insert(Changed, Key)
		end
	end
	return Changed, Count
end

local function AddedKeyFailure(Changed: { unknown }, Old: Tree, Level: number): Failure?
	for _, Key in Changed do
		if Old[Key] ~= nil then
			continue
		end
		local Failure = Storable.KeyFailure(Key, Level)
		if Failure ~= nil then
			return Failure
		end
	end
	return nil
end

local function AddedKeys(Changed: { unknown }, Old: Tree): (number, number)
	local AddedNumbers = 0
	local AddedStrings = 0
	for _, Key in Changed do
		if Old[Key] ~= nil then
			continue
		end
		if type(Key) == "number" then
			AddedNumbers += 1
		else
			AddedStrings += 1
		end
	end
	return AddedNumbers, AddedStrings
end

local function BytesAfter(Inner: unknown, NewTables: NewTables): number
	if type(Inner) == "table" then
		local Facts = NewTables[Inner :: Tree]
		if Facts ~= nil then
			return Facts.Bytes
		end
	end
	return Json.Size(Inner)
end

local function EntryChange(New: Tree, Old: Tree, Changed: { unknown }, Removed: number, NewTables: NewTables): number
	local Change = 0
	for _, Key in Changed do
		Change += Json.EntryBytes(New, Key, BytesAfter(New[Key], NewTables))
		local Before = Old[Key]
		if Before ~= nil then
			Change -= Json.EntryBytes(Old, Key, Json.Size(Before))
		end
	end
	if Removed > 0 then
		for Key, Before in Old do
			if New[Key] == nil then
				Change -= Json.EntryBytes(Old, Key, Json.Size(Before))
			end
		end
	end
	return Change
end

local function HeightAfter(Inner: unknown, NewTables: NewTables): number?
	if type(Inner) ~= "table" then
		return 0
	end
	local Facts = NewTables[Inner :: Tree]
	if Facts ~= nil then
		return Facts.Height
	end
	return Vetted.HeightOf(Inner :: Tree)
end

local function HeightAfterChanges(
	New: Tree,
	Changed: { unknown },
	Count: number,
	OldHeight: number,
	NewTables: NewTables
): number?
	local Height = if Count > #Changed then OldHeight else 0
	for _, Key in Changed do
		local Below = HeightAfter(New[Key], NewTables)
		if Below == nil then
			return nil
		end
		Height = math.max(Height, Below + 1)
	end
	return Height
end

local CheckChild: (Search: Search, Inner: unknown, Before: unknown, Level: number, NewTables: NewTables) -> Failure?

local function ChangedFailure(
	Search: Search,
	New: Tree,
	Old: Tree,
	Changed: { unknown },
	Level: number,
	NewTables: NewTables
): Failure?
	Search.Seen[New] = true
	for _, Key in Changed do
		Search.Keys[Level + 1] = Key
		local Failure = CheckChild(Search, New[Key], Old[Key], Level + 1, NewTables)
		if Failure ~= nil then
			return Failure
		end
	end
	Search.Seen[New] = nil
	return nil
end

local function CheckAgainst(
	Search: Search,
	New: Tree,
	Old: Tree,
	OldHeight: number,
	OldCount: number,
	Level: number,
	NewTables: NewTables
): Failure?
	if not Storable.Fits(Level, OldHeight) then
		return Storable.VisitTable(Search, New, Level)
	end
	local Entry = Storable.TableFailure(Search, New, Level)
	if Entry ~= nil then
		return Entry
	end

	local Changed, Count = ChangedKeys(New, Old)
	if #Changed == 0 and Count == OldCount then
		NewTables[New] = { Height = OldHeight, Bytes = Json.Size(Old), Count = OldCount }
		return nil
	end
	local AddedKey = AddedKeyFailure(Changed, Old, Level)
	if AddedKey ~= nil then
		return AddedKey
	end

	local AddedNumbers, AddedStrings = AddedKeys(Changed, Old)
	local Added = AddedNumbers + AddedStrings
	local Kept = Count - Added
	local Removed = OldCount - Kept
	local OldIsArray = Old[1] ~= nil
	local Numbers = AddedNumbers + (if OldIsArray then Kept else 0)
	local Strings = AddedStrings + (if OldIsArray then 0 else Kept)
	local Mixed = Storable.KindFailure(Numbers, Strings, Level)
	if Mixed ~= nil then
		return Mixed
	end
	if Added > 0 or Removed > 0 then
		local Gap = Storable.GapFailure(New, Numbers, Level)
		if Gap ~= nil then
			return Gap
		end
	end

	local Below = ChangedFailure(Search, New, Old, Changed, Level, NewTables)
	if Below ~= nil then
		return Below
	end

	local Change = EntryChange(New, Old, Changed, Removed, NewTables)
	NewTables[New] = {
		Height = HeightAfterChanges(New, Changed, Count, OldHeight, NewTables),
		Bytes = Json.ChangedBytes(Json.Size(Old), OldCount, Count, Change),
		Count = Count,
	}
	return nil
end

function CheckChild(Search: Search, Inner: unknown, Before: unknown, Level: number, NewTables: NewTables): Failure?
	local TooDeep = Storable.DepthFailure(Level)
	if TooDeep ~= nil then
		return TooDeep
	end
	if type(Inner) ~= "table" then
		return Storable.ScalarFailure(Inner, Level)
	end

	local Held = Inner :: Tree
	if Storable.IsCovered(Held, Level) then
		return nil
	end
	if type(Before) == "table" then
		local OldHeight = Vetted.HeightOf(Before :: Tree)
		local OldCount = Vetted.CountOf(Before :: Tree)
		if OldHeight ~= nil and OldCount ~= nil then
			return CheckAgainst(Search, Held, Before :: Tree, OldHeight, OldCount, Level, NewTables)
		end
	end
	return Storable.VisitTable(Search, Held, Level)
end

local function Check(Value: Tree, Old: Tree, Where: string, NewTables: NewTables): string?
	local Search: Search = { Keys = {}, Seen = {} }
	local Failure = CheckChild(Search, Value, Old, RootLevel, NewTables)
	if Failure == nil then
		return nil
	end
	return Storable.TextOf(Search, Failure, Where)
end

local function VetMade(NewTables: NewTables): ()
	for Held, Facts in NewTables do
		local Height = Facts.Height
		if Height == nil or not Storable.Fits(RootLevel, Height) then
			continue
		end
		if not table.isfrozen(Held) then
			table.freeze(Held)
		end
		Vetted.Add(Held, Height, Facts.Count)
		Json.KeepSize(Held, Facts.Bytes)
	end
end

local function VetSubsetOf(Input: unknown, Basis: Tree?): ()
	if Basis == nil or type(Input) ~= "table" then
		return
	end
	local Held = Input :: Tree
	if table.isfrozen(Held) or Storable.MetatableFailure(Held, RootLevel) ~= nil or Basis[1] ~= nil then
		return
	end
	local BasisHeight = Vetted.HeightOf(Basis)
	if BasisHeight == nil then
		return
	end

	local Count = 0
	for Key, Inner in Held do
		if Basis[Key] ~= Inner then
			return
		end
		Count += 1
	end
	table.freeze(Held)
	Vetted.Add(Held, BasisHeight, Count)
	local BasisBytes = Json.KnownSize(Basis)
	if BasisBytes ~= nil and Vetted.CountOf(Basis) == Count then
		Json.KeepSize(Held, BasisBytes)
	end
end

local function TrustedOld(Basis: Tree?, Input: unknown): Tree?
	if Basis ~= nil and Vetted.IsVetted(Basis) then
		return Basis
	end
	if type(Input) == "table" and Vetted.IsVetted(Input :: Tree) then
		return Input :: Tree
	end
	return nil
end

return {
	Check = Check,
	VetMade = VetMade,
	VetSubsetOf = VetSubsetOf,
	TrustedOld = TrustedOld,
}
