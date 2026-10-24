--!strict
--!optimize 2

--[=[
	Post: the post diff "p" (spec/protocols/record/Format.md 8) as the JSON array that Json writes, sorted
	by path.

	EncodePost throws on a bad path, a Set whose value is nil (it would read back as a removal) and two
	entries with one path. The reader throws through Format.Malformed. DecodePost gives nil instead.

	Return type: A plain table of functions, and the PathStep and DiffEntry types.
	Example usage:
		Post.EncodePost({
			{ Kind = "Set", Path = { "Gold" }, Value = 5 },
			{ Kind = "Removed", Path = { "Bag", 1 } },
		}) --> { { { "Bag", 1 } }, { { "Gold" }, 5 } }
--]=]

local Format = require("../Encoding/Format")
local Messages = require("../Constants/Messages")
local Record = require("../Constants/Record")

export type PathStep = string | number

export type DiffEntry = { Kind: "Set", Path: { PathStep }, Value: unknown } | { Kind: "Removed", Path: { PathStep } }

local Malformed = Format.Malformed
local RequireWholeBelow = Format.RequireWholeBelow

local ModuleName = "Post"

local FirstIndex = 1
local IndexLimit = Record.VarintLimit

local RemovedEntryLength = 1
local SetEntryLength = 2

local NotAnArray = "a post or an entry is not an array"
local WrongEntryLength = "an entry is neither a path alone nor a path and a value"
local OutOfOrder = "an entry does not sort after the one above it"
local PathProblem = `{ModuleName}: a path is an array of one or more steps. {Messages.KeepInRange}`
local MissingValue = `{ModuleName}: a Set entry must carry a value, since [path] alone reads back as a removal`
local RepeatedPath = `{ModuleName}: two entries share one path. {Messages.KeepInRange}`

local function StepProblem(Step: unknown): string
	return `{ModuleName}: a path step is a string or a whole number from {FirstIndex}, got {tostring(Step)}. `
		.. Messages.KeepInRange
end

local function ItemsOf(Value: unknown): { unknown }?
	if type(Value) ~= "table" then
		return nil
	end
	local Items: { unknown } = {}
	local Count = 0
	for _, Item in Value do
		Count += 1
		Items[Count] = Item
	end
	if Count ~= #Value then
		return nil
	end
	return Items
end

local function CheckPath(Path: unknown): { PathStep }
	local Items = ItemsOf(Path)
	if Items == nil or #Items == 0 then
		error(PathProblem)
	end
	local Steps: { PathStep } = {}
	for Index, Step in Items do
		if type(Step) == "string" then
			Steps[Index] = Step
		elseif type(Step) == "number" then
			if Step < FirstIndex then
				error(StepProblem(Step))
			end
			RequireWholeBelow(ModuleName, "a path step", Step, IndexLimit)
			Steps[Index] = Step
		else
			error(StepProblem(Step))
		end
	end
	return Steps
end

local function StepBefore(Left: PathStep, Right: PathStep): boolean
	if type(Left) == "number" and type(Right) == "number" then
		return Left < Right
	end
	if type(Left) == "number" then
		return true
	end
	if type(Right) == "number" then
		return false
	end
	return Left < Right
end

local function PathBefore(Left: { PathStep }, Right: { PathStep }): boolean
	for Index = 1, math.min(#Left, #Right) do
		if Left[Index] ~= Right[Index] then
			return StepBefore(Left[Index], Right[Index])
		end
	end
	return #Left < #Right
end

local function EntryBefore(Left: DiffEntry, Right: DiffEntry): boolean
	return PathBefore(Left.Path, Right.Path)
end

local function EncodePost(Diff: { DiffEntry }): { unknown }
	for _, Entry in Diff do
		CheckPath(Entry.Path)
		if Entry.Kind == "Set" and Entry.Value == nil then
			error(MissingValue)
		end
	end
	local Sorted = table.clone(Diff)
	table.sort(Sorted, EntryBefore)
	for Index = 2, #Sorted do
		if not EntryBefore(Sorted[Index - 1], Sorted[Index]) then
			error(RepeatedPath)
		end
	end

	local Raw: { unknown } = {}
	for Index, Entry in Sorted do
		if Entry.Kind == "Removed" then
			Raw[Index] = { Entry.Path }
		else
			Raw[Index] = { Entry.Path, Entry.Value }
		end
	end
	return Raw
end

local function ReadEntry(Raw: unknown): DiffEntry
	local Parts = ItemsOf(Raw)
	if Parts == nil then
		return Malformed(NotAnArray)
	end
	if #Parts == RemovedEntryLength then
		return { Kind = "Removed", Path = CheckPath(Parts[1]) }
	end
	if #Parts == SetEntryLength then
		return { Kind = "Set", Path = CheckPath(Parts[1]), Value = Parts[2] }
	end
	return Malformed(WrongEntryLength)
end

local function ReadPost(Raw: unknown): { DiffEntry }
	local Items = ItemsOf(Raw)
	if Items == nil then
		return Malformed(NotAnArray)
	end
	local Diff: { DiffEntry } = {}
	for Index, Item in Items do
		local Entry = ReadEntry(Item)
		if Index > 1 and not EntryBefore(Diff[Index - 1], Entry) then
			Malformed(OutOfOrder)
		end
		Diff[Index] = Entry
	end
	return Diff
end

local function DecodePost(Raw: unknown): { DiffEntry }?
	local Succeeded, Diff = pcall(ReadPost, Raw)
	if not Succeeded then
		return nil
	end
	return Diff
end

return {
	FirstIndex = FirstIndex,
	CheckPath = CheckPath,
	PathBefore = PathBefore,
	EntryBefore = EntryBefore,
	EncodePost = EncodePost,
	ReadPost = ReadPost,
	DecodePost = DecodePost,
}
