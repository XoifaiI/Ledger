--!strict
--!optimize 2

--[=[
	PostDiff: an exclusive mark's post diff (transaction sheet 3.2, spec/protocols/record/Format.md 8):
	computing it, its size against PostCap, applying it, and writing the decider value into it at a slot.
	Post owns the stored form.

	ApplyDiff copies along each path, so a frozen state is never written. A path through a field that is no
	table throws.

	Return type: A plain table of functions.
	Example usage:
		local Diff = PostDiff.DiffStates({ Gold = 5, Bag = { 1 } }, { Gold = 7, Bag = { 1 } })
		--> { { Kind = "Set", Path = { "Gold" }, Value = 7 } }
		PostDiff.ApplyDiff({ Gold = 5, Bag = { 1 } }, Diff) --> { Gold = 7, Bag = { 1 } }
--]=]

local Json = require("../../Encoding/Json")
local Post = require("../../Stored/Post")

type PathStep = Post.PathStep
type DiffEntry = Post.DiffEntry
type Tree = { [unknown]: unknown }

local CheckPath = Post.CheckPath
local EntryBefore = Post.EntryBefore
local PathBefore = Post.PathBefore
local EncodePost = Post.EncodePost

local ModuleName = "PostDiff"
local PathNotInState =
	`{ModuleName}: a path runs through a field that is not a table. A diff applies to the state it was made on`

local function IsArray(Subtree: Tree): boolean
	return Subtree[1] ~= nil
end

local function IsSameShape(Before: Tree, After: Tree): boolean
	local IsBeforeArray = IsArray(Before)
	if IsBeforeArray ~= IsArray(After) then
		return false
	end
	if not IsBeforeArray then
		return true
	end
	return #Before == #After
end

local function PathTo(Path: { unknown }, Step: unknown): { unknown }
	local Longer = table.clone(Path)
	table.insert(Longer, Step)
	return Longer
end

local function AddWhole(Out: { DiffEntry }, Path: { unknown }, Value: unknown)
	local Entry: DiffEntry = { Kind = "Set", Path = CheckPath(Path), Value = Value }
	table.insert(Out, Entry)
end

local function DiffInto(Before: unknown, After: unknown, Path: { unknown }, Out: { DiffEntry })
	if Before == After then
		return
	end
	if type(Before) ~= "table" or type(After) ~= "table" then
		AddWhole(Out, Path, After)
		return
	end
	local BeforeTree = Before :: Tree
	local AfterTree = After :: Tree
	if not IsSameShape(BeforeTree, AfterTree) then
		AddWhole(Out, Path, After)
		return
	end
	for Key in BeforeTree do
		if AfterTree[Key] == nil then
			local Entry: DiffEntry = { Kind = "Removed", Path = CheckPath(PathTo(Path, Key)) }
			table.insert(Out, Entry)
		end
	end
	for Key, Value in AfterTree do
		DiffInto(BeforeTree[Key], Value, PathTo(Path, Key), Out)
	end
end

local function DiffStates(Before: Tree, After: Tree): { DiffEntry }
	local Out: { DiffEntry } = {}
	DiffInto(Before, After, {}, Out)
	table.sort(Out, EntryBefore)
	return Out
end

local function DiffBytes(Diff: { DiffEntry }): number
	return Json.Size(EncodePost(Diff))
end

local function CopyAlong(Root: Tree, Path: { PathStep }): (Tree?, Tree?)
	local RootCopy = table.clone(Root)
	local Parent = RootCopy
	for Index = 1, #Path - 1 do
		local Step = Path[Index]
		local Child = Parent[Step]
		if type(Child) ~= "table" then
			return nil, nil
		end
		local ChildCopy = table.clone(Child :: Tree)
		Parent[Step] = ChildCopy
		Parent = ChildCopy
	end
	return RootCopy, Parent
end

local function ApplyEntry(Root: Tree, Entry: DiffEntry): Tree?
	local NewRoot, Parent = CopyAlong(Root, Entry.Path)
	if NewRoot == nil or Parent == nil then
		return nil
	end
	if Entry.Kind == "Removed" then
		Parent[Entry.Path[#Entry.Path]] = nil
	else
		Parent[Entry.Path[#Entry.Path]] = Entry.Value
	end
	return NewRoot
end

local function Applies(Root: Tree, Diff: { DiffEntry }): boolean
	local Applied = Root
	for _, Entry in Diff do
		local Next = ApplyEntry(Applied, Entry)
		if Next == nil then
			return false
		end
		Applied = Next
	end
	return true
end

local function ApplyDiff(Root: Tree, Diff: { DiffEntry }): Tree
	local Applied = Root
	for _, Entry in Diff do
		local Next = ApplyEntry(Applied, Entry)
		if Next == nil then
			error(PathNotInState)
		end
		Applied = Next
	end
	return Applied
end

local function WriteSlot(Diff: { DiffEntry }, Slot: { PathStep }, DeciderValue: number): { DiffEntry }
	local SlotEntry: DiffEntry = { Kind = "Set", Path = Slot, Value = DeciderValue }
	local Slotted = table.clone(Diff)
	for Index, Entry in Diff do
		if PathBefore(Entry.Path, Slot) then
			continue
		end
		if PathBefore(Slot, Entry.Path) then
			table.insert(Slotted, Index, SlotEntry)
		else
			Slotted[Index] = SlotEntry
		end
		return Slotted
	end
	table.insert(Slotted, SlotEntry)
	return Slotted
end

return {
	DiffStates = DiffStates,
	DiffBytes = DiffBytes,
	Applies = Applies,
	ApplyDiff = ApplyDiff,
	WriteSlot = WriteSlot,
}
