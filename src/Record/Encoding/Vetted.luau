--!strict
--!optimize 2

--[=[
	Vetted: the tables Ledger froze itself and checked storable, each with its height (the levels of values below it)
	and its key count.

	A frozen table cannot change, and a table is vetted only when every table inside it is vetted, so both facts
	hold for the table's life and do not depend on where it sits. table.isfrozen alone proves nothing: a table the
	game froze was never checked. Keys are weak, so a vetted table is collected like any other.

	Return type: A table with Add, IsVetted, HeightOf and CountOf.
	Example usage:
		Vetted.Add(Frozen, Height, Count)
		Vetted.HeightOf(Frozen) --> Height
--]=]

type Tree = { [unknown]: unknown }

local ModuleName = "Vetted"
local AddedUnfrozen = `{ModuleName}: only a frozen table is vetted. The caller must freeze it before checking it`

local WeakKeys = { __mode = "k" }

local Heights = setmetatable({} :: { [Tree]: number }, WeakKeys)
local Counts = setmetatable({} :: { [Tree]: number }, WeakKeys)

local function Add(Held: Tree, Height: number, Count: number): ()
	if not table.isfrozen(Held) then
		error(AddedUnfrozen)
	end
	Heights[Held] = Height
	Counts[Held] = Count
end

local function IsVetted(Held: Tree): boolean
	return Heights[Held] ~= nil
end

local function HeightOf(Held: Tree): number?
	return Heights[Held]
end

local function CountOf(Held: Tree): number?
	return Counts[Held]
end

return {
	Add = Add,
	IsVetted = IsVetted,
	HeightOf = HeightOf,
	CountOf = CountOf,
}
