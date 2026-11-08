--!strict
--!optimize 2
--!native

--[=[
	Splice: a vetted state's canonical JSON written from the canonical text of the vetted state it came from, copying
	the bytes of each entry whose value is the same table or an equal value and writing only what changed.

	A table's text depends on its content alone (Json), so an unchanged entry keeps its bytes. The caller vouches for
	BasisText being Basis's canonical text, and the result is CanonicalJson(State)'s bytes with the count
	Json.WriteLaidOut gives. KeepChanges keeps the keys StorableChange found changed against the table it came from.

	Return type: A table with Canonical and KeepChanges.
	Example usage:
		local Written, ReadsBack = Splice.Canonical(State, Basis, BasisText)
--]=]

local Escapes = require("./Escapes")
local Format = require("./Format")
local Json = require("./Json")
local Layouts = require("./Layouts")
local Vetted = require("./Vetted")

type Writer = Format.Writer
type Tree = { [unknown]: unknown }
type Layout = Layouts.Layout
type Patches = Layouts.Patches

type Tracking =
	{ read Kind: "Patches", read Patches: Patches }
	| { read Kind: "Starts", read Starts: buffer }
	| { read Kind: "Untracked" }

type TableRun = {
	Out: Writer,
	Text: buffer,
	At: number,
	Old: Layout,
	OldBytes: number,
	TableStart: number,
	Tracking: Tracking,
	Written: number,
}

local Grow = Format.Grow
local WriteLaidOut = Json.WriteLaidOut
local SizeOf = Vetted.SizeOf
local StringBytes = Json.StringBytes
local EntryLossy = Json.EntryLossy
local StartOf = Layouts.StartOf
local StopOf = Layouts.StopOf

local LayoutFrom = Layouts.LayoutFrom
local StartBytes = Layouts.StartBytes
local MostlyChanged = 0.5
local ScratchCapacity = 64

local OpenArrayByte = string.byte("[")
local CloseArrayByte = string.byte("]")
local OpenObjectByte = string.byte("{")
local CloseObjectByte = string.byte("}")
local CommaByte = string.byte(",")
local ColonByte = string.byte(":")
local ColonBytes = 1
local CommaBytes = 1
local OpenBytes = 1

local ModuleName = "Splice"
local SplicedUnvetted = `{ModuleName}: a table spliced from, or with changes kept, is vetted and keeps its count.`
	.. " The caller must vet it first"

local Untracked: Tracking = table.freeze({ Kind = "Untracked" :: "Untracked" })

local Scratch = Format.NewWriter(ScratchCapacity)

local ChangedLists = setmetatable({} :: { [Tree]: { unknown } }, { __mode = "k" })
local ChangedFrom = setmetatable({} :: { [Tree]: Tree }, { __mode = "kv" })

local function WriteByte(Out: Writer, Byte: number): ()
	local Cursor = Out.Cursor
	if Cursor == Out.Size then
		Grow(Out, Cursor, 1)
	end
	buffer.writeu8(Out.Buffer, Cursor, Byte)
	Out.Cursor = Cursor + 1
end

local function CopyBytes(Out: Writer, Source: buffer, From: number, Count: number): ()
	local Cursor = Out.Cursor
	if Cursor + Count > Out.Size then
		Grow(Out, Cursor, Count)
	end
	buffer.copy(Out.Buffer, Cursor, Source, From, Count)
	Out.Cursor = Cursor + Count
end

local function ChangesFrom(Held: Tree, Old: Tree): { unknown }?
	if ChangedFrom[Held] ~= Old then
		return nil
	end
	return ChangedLists[Held]
end

local function SortedKeys(Old: Tree): { string }
	local Sorted: { string } = {}
	local Index = 0
	for Key in Old do
		Index += 1
		Sorted[Index] = Key :: string
	end
	table.sort(Sorted)
	return Sorted
end

local function WorkedLayout(Old: Tree, IsArray: boolean, Count: number): Layout
	local Keys = if IsArray then nil else SortedKeys(Old)
	local Starts = buffer.create(Count * StartBytes)
	local At = OpenBytes
	for Index = 1, Count do
		Layouts.WriteStart(Starts, Index, At)
		if Keys then
			local Key = Keys[Index]
			At += StringBytes(Key) + ColonBytes + Json.Size(Old[Key]) + CommaBytes
		else
			At += Json.Size(Old[Index]) + CommaBytes
		end
	end
	return Layouts.New(Starts, Count, Keys)
end

local function NewRun(
	Out: Writer,
	Text: buffer,
	At: number,
	Old: Layout,
	OldBytes: number,
	Tracking: Tracking
): TableRun
	return {
		Out = Out,
		Text = Text,
		At = At,
		Old = Old,
		OldBytes = OldBytes,
		TableStart = Out.Cursor,
		Tracking = Tracking,
		Written = 0,
	}
end

local function PatchingRun(Out: Writer, Text: buffer, At: number, Old: Layout, OldBytes: number): TableRun
	local Tracking: Tracking = { Kind = "Patches" :: "Patches", Patches = {} }
	return NewRun(Out, Text, At, Old, OldBytes, Tracking)
end

local function RelaidRun(
	Out: Writer,
	Text: buffer,
	At: number,
	Old: Layout,
	OldBytes: number,
	Count: number
): TableRun
	local Tracking = Untracked
	if Layouts.KeepsLayout(Count, OldBytes) then
		local Laying: Tracking = { Kind = "Starts" :: "Starts", Starts = buffer.create(Count * StartBytes) }
		Tracking = Laying
	end
	return NewRun(Out, Text, At, Layouts.Materialized(Old), OldBytes, Tracking)
end

local function CopyEntries(Run: TableRun, First: number, Last: number): ()
	local Out = Run.Out
	if Run.Written > 0 then
		WriteByte(Out, CommaByte)
	end
	local Old = Run.Old
	local From = StartOf(Old, First)
	local Moved = Out.Cursor - Run.TableStart - From
	CopyBytes(Out, Run.Text, Run.At + From, StopOf(Old, Run.OldBytes, Last) - From)
	local Tracking = Run.Tracking
	if Tracking.Kind == "Starts" then
		Layouts.CopyStarts(Tracking.Starts, Run.Written + 1, Old, First, Last, Moved)
	end
	Run.Written += Last - First + 1
end

local function BeginEntry(Run: TableRun): number
	local Out = Run.Out
	if Run.Written > 0 then
		WriteByte(Out, CommaByte)
	end
	local Start = Out.Cursor - Run.TableStart
	local Tracking = Run.Tracking
	if Tracking.Kind == "Starts" then
		Layouts.WriteStart(Tracking.Starts, Run.Written + 1, Start)
	end
	return Start
end

local function EndEntry(Run: TableRun, Start: number, OldIndex: number): ()
	local Tracking = Run.Tracking
	if Tracking.Kind == "Patches" then
		local Old = Run.Old
		local OldEntryBytes = StopOf(Old, Run.OldBytes, OldIndex) - StartOf(Old, OldIndex)
		local Grown = Run.Out.Cursor - Run.TableStart - Start - OldEntryBytes
		if Grown ~= 0 then
			Layouts.AddPatch(Tracking.Patches, OldIndex, Grown)
		end
	end
	Run.Written += 1
end

local function EndAdded(Run: TableRun): ()
	Run.Written += 1
end

local function Finish(Run: TableRun, New: Tree, Count: number): ()
	local Tracking = Run.Tracking
	if Tracking.Kind == "Patches" then
		Layouts.Keep(New, Layouts.Patched(Run.Old, Tracking.Patches))
	elseif Tracking.Kind == "Starts" then
		Layouts.Keep(New, Layouts.New(Tracking.Starts, Count))
	end
end

local function CountOfVetted(Held: Tree): number
	local Count = Vetted.CountOf(Held)
	if Count == nil then
		error(SplicedUnvetted)
	end
	return Count
end

local function Changes(New: Tree, Old: Tree): ({ unknown }, number)
	local Carried = ChangesFrom(New, Old)
	if Carried ~= nil then
		return Carried, CountOfVetted(New)
	end
	return Json.ChangedKeys(New, Old)
end

local WriteFrom: (Out: Writer, New: unknown, Old: unknown, Text: buffer, At: number) -> number

local function SpliceArray(Out: Writer, New: Tree, Old: Tree, Text: buffer, At: number, OldBytes: number): number
	local OldCount = #Old
	local Changed, Count = Changes(New, Old)
	if Count >= LayoutFrom and #Changed > math.max(Count, OldCount) * MostlyChanged then
		return WriteLaidOut(Out, New)
	end
	table.sort(Changed)
	local Kept = Layouts.Of(Old)
	local Run: TableRun
	if Kept ~= nil and Count == OldCount then
		Run = PatchingRun(Out, Text, At, Kept, OldBytes)
	else
		Run = RelaidRun(Out, Text, At, Kept or WorkedLayout(Old, true, OldCount), OldBytes, Count)
	end
	local Lossy = Json.LossyCount(Old)
	WriteByte(Out, OpenArrayByte)
	local Next = 1
	for _, Changing in Changed do
		local Index = Changing :: number
		if Index > Next then
			CopyEntries(Run, Next, Index - 1)
		end
		local Start = BeginEntry(Run)
		local Inner = New[Index]
		if Index <= OldCount then
			local Before = Old[Index]
			Lossy -= EntryLossy(Before)
			Lossy += WriteFrom(Out, Inner, Before, Text, At + StartOf(Run.Old, Index))
			EndEntry(Run, Start, Index)
		else
			Lossy += WriteLaidOut(Out, Inner)
			EndAdded(Run)
		end
		Next = Index + 1
	end
	local Last = math.min(Count, OldCount)
	if Next <= Last then
		CopyEntries(Run, Next, Last)
	end
	for Gone = Count + 1, OldCount do
		Lossy -= EntryLossy(Old[Gone])
	end
	WriteByte(Out, CloseArrayByte)
	Finish(Run, New, Count)
	Json.KeepLossy(New, Lossy)
	return Lossy
end

local function FirstNotBelow(Run: TableRun, Key: string, From: number, Count: number): (number, boolean)
	local Keys = Run.Old.Keys
	local Low = From
	local High = Count + 1
	local Found = false
	while Low < High do
		local Middle = (Low + High) // 2
		local Order: number
		if Keys then
			Order = if Keys[Middle] < Key then -1 elseif Keys[Middle] == Key then 0 else 1
		else
			Order = Escapes.CompareWritten(Run.Text, Run.At + StartOf(Run.Old, Middle), Key)
		end
		if Order < 0 then
			Low = Middle + 1
		else
			High = Middle
			Found = Order == 0
		end
	end
	return Low, Found and Low <= Count
end

local function AddedCount(Changed: { unknown }, Old: Tree): number
	local Added = 0
	for _, Key in Changed do
		if Old[Key] == nil then
			Added += 1
		end
	end
	return Added
end

local function WithRemoved(Changed: { unknown }, New: Tree, Old: Tree): { unknown }
	local Whole = table.clone(Changed)
	for Key in Old do
		if New[Key] == nil then
			table.insert(Whole, Key)
		end
	end
	return Whole
end

local function CopyWhole(Out: Writer, New: Tree, Old: Tree, Text: buffer, At: number, OldBytes: number): number
	CopyBytes(Out, Text, At, OldBytes)
	local Kept = Layouts.Of(Old)
	if Kept then
		Layouts.Keep(New, Kept)
	end
	local Lossy = Json.LossyCount(Old)
	Json.KeepLossy(New, Lossy)
	return Lossy
end

local function SpliceObject(Out: Writer, New: Tree, Old: Tree, Text: buffer, At: number, OldBytes: number): number
	local OldCount = CountOfVetted(Old)
	local Changed, Count = Changes(New, Old)
	local Added = AddedCount(Changed, Old)
	local Removed = OldCount - (Count - Added)
	if Removed > 0 then
		Changed = WithRemoved(Changed, New, Old)
	end
	if Count >= LayoutFrom and #Changed > (Count + Removed) * MostlyChanged then
		return WriteLaidOut(Out, New)
	end
	if #Changed == 0 then
		return CopyWhole(Out, New, Old, Text, At, OldBytes)
	end
	table.sort(Changed)

	local Kept = Layouts.Of(Old)
	local Run: TableRun
	if Kept ~= nil and Added == 0 and Removed == 0 then
		Run = PatchingRun(Out, Text, At, Kept, OldBytes)
	else
		Run = RelaidRun(Out, Text, At, Kept or WorkedLayout(Old, false, OldCount), OldBytes, Count)
	end
	local Lossy = Json.LossyCount(Old)
	WriteByte(Out, OpenObjectByte)
	local Next = 1
	for _, Changing in Changed do
		local Key = Changing :: string
		local Place, Found = FirstNotBelow(Run, Key, Next, OldCount)
		if Place > Next then
			CopyEntries(Run, Next, Place - 1)
		end
		local Inner = New[Key]
		local Before = if Found then Old[Key] else nil
		if Found then
			Lossy -= EntryLossy(Before)
		end
		if Inner ~= nil then
			local Start = BeginEntry(Run)
			Json.WriteString(Out, Key)
			WriteByte(Out, ColonByte)
			if Found then
				local ValueAt = Run.At + StartOf(Run.Old, Place) + StringBytes(Key) + ColonBytes
				Lossy += WriteFrom(Out, Inner, Before, Text, ValueAt)
				EndEntry(Run, Start, Place)
			else
				Lossy += WriteLaidOut(Out, Inner)
				EndAdded(Run)
			end
		end
		Next = if Found then Place + 1 else Place
	end
	if Next <= OldCount then
		CopyEntries(Run, Next, OldCount)
	end
	WriteByte(Out, CloseObjectByte)
	Finish(Run, New, Count)
	Json.KeepLossy(New, Lossy)
	return Lossy
end

function WriteFrom(Out: Writer, New: unknown, Old: unknown, Text: buffer, At: number): number
	if type(New) ~= "table" or type(Old) ~= "table" then
		return WriteLaidOut(Out, New)
	end
	local OldTree = Old :: Tree
	local OldBytes = SizeOf(OldTree)
	if OldBytes == nil then
		return WriteLaidOut(Out, New)
	end
	if New == Old then
		CopyBytes(Out, Text, At, OldBytes)
		return Json.LossyCount(OldTree)
	end
	local NewTree = New :: Tree
	local OldIsArray = OldTree[1] ~= nil
	if OldIsArray ~= (NewTree[1] ~= nil) or next(OldTree) == nil or next(NewTree) == nil then
		return WriteLaidOut(Out, New)
	end
	local Start = Out.Cursor
	local Lossy = if OldIsArray
		then SpliceArray(Out, NewTree, OldTree, Text, At, OldBytes)
		else SpliceObject(Out, NewTree, OldTree, Text, At, OldBytes)
	if SizeOf(NewTree) == nil and Vetted.IsVetted(NewTree) then
		Vetted.KeepSize(NewTree, Out.Cursor - Start)
	end
	return Lossy
end

local function Canonical(State: Tree, Basis: Tree?, BasisText: buffer?): (buffer, boolean)
	local Out = Scratch
	Out.Cursor = 0
	local Lossy: number
	if Basis ~= nil and BasisText ~= nil and SizeOf(Basis) == buffer.len(BasisText) then
		Lossy = WriteFrom(Out, State, Basis, BasisText, 0)
	else
		Lossy = WriteLaidOut(Out, State)
	end
	return Format.ToBuffer(Out), Lossy == 0
end

local function KeepChanges(Held: Tree, Old: Tree, Changed: { unknown }): ()
	if Vetted.IsVetted(Held) and Vetted.IsVetted(Old) then
		ChangedLists[Held] = Changed
		ChangedFrom[Held] = Old
	end
end

return {
	Canonical = Canonical,
	KeepChanges = KeepChanges,
}
