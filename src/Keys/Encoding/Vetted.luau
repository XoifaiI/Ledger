--!strict
--!optimize 2

--[=[
	Vetted: the tables Ledger froze itself and checked storable, each with its height (the levels of values below it),
	its key count and, once kept, its canonical JSON size.

	A frozen table cannot change, and a table is vetted only when every table inside it is vetted, so the facts hold
	for the table's life and do not depend on where it sits. table.isfrozen alone proves nothing: a table the game
	froze was never checked. The facts are packed into one number while each fits its span, and kept exact in a
	second map once one does not; a table is in exactly one of the two. Keys are weak, so a vetted table is collected.

	Return type: A table with Add, IsVetted, HeightOf, CountOf, SizeOf and KeepSize.
	Example usage:
		Vetted.Add(Frozen, Height, Count)
		Vetted.HeightOf(Frozen) --> Height
--]=]

local Record = require("../Constants/Record")

type Tree = { [unknown]: unknown }

type ExactFacts = {
	read Height: number,
	read Count: number,
	read Size: number?,
}

local ModuleName = "Vetted"
local AddedUnfrozen = `{ModuleName}: only a frozen table is vetted. The caller must freeze it before checking it`
local KeptUnvetted = `{ModuleName}: only a vetted table keeps its size. The caller must vet it first`

local HeightSpan = 2 ^ (math.floor(math.log(Record.StorableDepthMax, 2)) + 1)
local CountAndSizeSpan = Record.VarintLimit / HeightSpan
local CountSpan = math.sqrt(CountAndSizeSpan)
local SizeSpan = CountAndSizeSpan / CountSpan
local SizeUnknown = 0
local SizePlace = HeightSpan * CountSpan

local WeakKeys = { __mode = "k" }

local Packed = setmetatable({} :: { [Tree]: number }, WeakKeys)
local Exacts = setmetatable({} :: { [Tree]: ExactFacts }, WeakKeys)

local function SizeField(Size: number?): number
	if Size == nil then
		return SizeUnknown
	end
	return Size + 1
end

local function PackedHeight(Facts: number): number
	return Facts % HeightSpan
end

local function PackedCount(Facts: number): number
	return Facts % SizePlace // HeightSpan
end

local function PackedSize(Facts: number): number?
	local Field = Facts // SizePlace
	if Field == SizeUnknown then
		return nil
	end
	return Field - 1
end

local function FitsSpans(Height: number, Count: number, Field: number): boolean
	return Height < HeightSpan and Count < CountSpan and Field < SizeSpan
end

local function Keep(Held: Tree, Height: number, Count: number, Size: number?): ()
	local Field = SizeField(Size)
	if FitsSpans(Height, Count, Field) then
		Packed[Held] = Field * SizePlace + Count * HeightSpan + Height
		Exacts[Held] = nil
		return
	end
	Packed[Held] = nil
	Exacts[Held] = table.freeze({ Height = Height, Count = Count, Size = Size })
end

local function HeightOf(Held: Tree): number?
	local Facts = Packed[Held]
	if Facts ~= nil then
		return PackedHeight(Facts)
	end
	local Exact = Exacts[Held]
	if Exact == nil then
		return nil
	end
	return Exact.Height
end

local function CountOf(Held: Tree): number?
	local Facts = Packed[Held]
	if Facts ~= nil then
		return PackedCount(Facts)
	end
	local Exact = Exacts[Held]
	if Exact == nil then
		return nil
	end
	return Exact.Count
end

local function SizeOf(Held: Tree): number?
	local Facts = Packed[Held]
	if Facts ~= nil then
		return PackedSize(Facts)
	end
	local Exact = Exacts[Held]
	if Exact == nil then
		return nil
	end
	return Exact.Size
end

local function IsVetted(Held: Tree): boolean
	return Packed[Held] ~= nil or Exacts[Held] ~= nil
end

local function Add(Held: Tree, Height: number, Count: number): ()
	if not table.isfrozen(Held) then
		error(AddedUnfrozen)
	end
	Keep(Held, Height, Count, SizeOf(Held))
end

local function KeepSize(Held: Tree, Bytes: number): ()
	local Facts = Packed[Held]
	if Facts ~= nil then
		Keep(Held, PackedHeight(Facts), PackedCount(Facts), Bytes)
		return
	end
	local Exact = Exacts[Held]
	if Exact == nil then
		error(KeptUnvetted)
	end
	Keep(Held, Exact.Height, Exact.Count, Bytes)
end

return {
	Add = Add,
	IsVetted = IsVetted,
	HeightOf = HeightOf,
	CountOf = CountOf,
	SizeOf = SizeOf,
	KeepSize = KeepSize,
}
