--!strict
--!optimize 2
--!native

--[=[
	Layouts: where each entry of a vetted table starts in the table's canonical text, kept for a table of LayoutFrom
	entries or more, or of LayoutBytes of text or more, so a splice copies runs of entries without a pass over them.

	Starts holds each entry's offset from the table's opening bracket as first written. Patches holds the entries
	rewritten since, each with its size change, in entry order, so an edit that keeps the keys costs no pass over the
	entries; past PatchMost of them the layout is rebuilt once. A layout never changes once made. Only a vetted table
	keeps one, since its text depends on its content alone (Json); Keys is set only on a layout worked out for a pass.

	Return type: A table of the layout functions and constants, and the Layout and Patches types.
	Example usage:
		local Start = Layouts.StartOf(Laid, 3)
--]=]

local Vetted = require("./Vetted")

type Tree = { [unknown]: unknown }

export type Patches = { number }

export type Layout = {
	read Starts: buffer,
	read Count: number,
	read Patches: Patches?,
	read Keys: { string }?,
}

local LayoutFrom = 16
local LayoutBytes = 4096
local StartBytes = 4
local PatchMost = 64
local PatchStride = 2
local ChangeAt = 1
local CommaBytes = 1
local CloseBytes = 1

local Kept = setmetatable({} :: { [Tree]: Layout }, { __mode = "k" })

local function New(Starts: buffer, Count: number, Keys: { string }?): Layout
	return { Starts = Starts, Count = Count, Patches = nil, Keys = Keys }
end

local function KeepsLayout(Count: number, TextBytes: number): boolean
	return Count >= LayoutFrom or TextBytes >= LayoutBytes
end

local function Keep(Held: Tree, Made: Layout): ()
	if Vetted.IsVetted(Held) then
		Kept[Held] = Made
	end
end

local function Of(Held: Tree): Layout?
	return Kept[Held]
end

local function FirstStart(Laid: Layout, Index: number): number
	return buffer.readu32(Laid.Starts, (Index - 1) * StartBytes)
end

local function WriteStart(Starts: buffer, Index: number, Start: number): ()
	buffer.writeu32(Starts, (Index - 1) * StartBytes, Start)
end

local function StartOf(Laid: Layout, Index: number): number
	local Start = FirstStart(Laid, Index)
	local Patches = Laid.Patches
	if Patches == nil then
		return Start
	end
	for Place = 1, #Patches, PatchStride do
		if Patches[Place] >= Index then
			break
		end
		Start += Patches[Place + ChangeAt]
	end
	return Start
end

local function StopOf(Laid: Layout, TextBytes: number, Index: number): number
	if Index < Laid.Count then
		return StartOf(Laid, Index + 1) - CommaBytes
	end
	return TextBytes - CloseBytes
end

local function Materialized(Laid: Layout): Layout
	local Patches = Laid.Patches
	if Patches == nil then
		return Laid
	end
	local Count = Laid.Count
	local Starts = buffer.create(Count * StartBytes)
	local Shift = 0
	local Place = 1
	for Index = 1, Count do
		while Place <= #Patches and Patches[Place] < Index do
			Shift += Patches[Place + ChangeAt]
			Place += PatchStride
		end
		WriteStart(Starts, Index, FirstStart(Laid, Index) + Shift)
	end
	return New(Starts, Count, Laid.Keys)
end

local function CopyStarts(Into: buffer, IntoFirst: number, From: Layout, First: number, Last: number, Moved: number): ()
	local Shift = IntoFirst - First
	for Index = First, Last do
		WriteStart(Into, Shift + Index, StartOf(From, Index) + Moved)
	end
end

local function AddPatch(Patches: Patches, Index: number, Change: number): ()
	table.insert(Patches, Index)
	table.insert(Patches, Change)
end

local function Merged(Older: Patches, Newer: Patches): Patches
	local Out: Patches = {}
	local Left = 1
	local Right = 1
	while Left <= #Older or Right <= #Newer do
		local LeftIndex = Older[Left]
		local RightIndex = Newer[Right]
		if RightIndex == nil or (LeftIndex ~= nil and LeftIndex < RightIndex) then
			AddPatch(Out, LeftIndex, Older[Left + ChangeAt])
			Left += PatchStride
		elseif LeftIndex == RightIndex then
			AddPatch(Out, LeftIndex, Older[Left + ChangeAt] + Newer[Right + ChangeAt])
			Left += PatchStride
			Right += PatchStride
		else
			AddPatch(Out, RightIndex, Newer[Right + ChangeAt])
			Right += PatchStride
		end
	end
	return Out
end

local function Patched(Laid: Layout, Newer: Patches): Layout
	local Older = Laid.Patches
	local Patches = if Older == nil then Newer else Merged(Older, Newer)
	local Made: Layout = { Starts = Laid.Starts, Count = Laid.Count, Patches = Patches, Keys = nil }
	if #Patches > PatchMost * PatchStride then
		return Materialized(Made)
	end
	return Made
end

return {
	LayoutFrom = LayoutFrom,
	StartBytes = StartBytes,
	New = New,
	KeepsLayout = KeepsLayout,
	Keep = Keep,
	Of = Of,
	WriteStart = WriteStart,
	StartOf = StartOf,
	StopOf = StopOf,
	Materialized = Materialized,
	CopyStarts = CopyStarts,
	AddPatch = AddPatch,
	Patched = Patched,
}
