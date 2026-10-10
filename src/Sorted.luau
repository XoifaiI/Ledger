--!strict
--!optimize 2

--[=[
	Sorted: the keys of a map in a fixed order, so a step that emits commands while walking a map emits them in an
	order the state fixes, never the table's iteration order. The Due forms keep only the entries a pass acts on.

	Return type: A plain table of functions.
	Example usage:
		for _, Id in Sorted.SortedIds(State.Tx.Calls) do ... end
--]=]

local function SortedIds<Item>(Items: { [number]: Item }): { number }
	local Ids: { number } = {}
	for Id in Items do
		table.insert(Ids, Id)
	end
	table.sort(Ids)
	return Ids
end

local function SortedTexts<Item>(Items: { [string]: Item }): { string }
	local Texts: { string } = {}
	for Text in Items do
		table.insert(Texts, Text)
	end
	table.sort(Texts)
	return Texts
end

local function SortedDueIds<Item>(Items: { [number]: Item }, IsDue: (number, Item) -> boolean): { number }
	local Ids: { number } = {}
	for Id, Held in Items do
		if IsDue(Id, Held) then
			table.insert(Ids, Id)
		end
	end
	table.sort(Ids)
	return Ids
end

local function SortedDueTexts<Item>(Items: { [string]: Item }, IsDue: (Item) -> boolean): { string }
	local Texts: { string } = {}
	for Text, Held in Items do
		if IsDue(Held) then
			table.insert(Texts, Text)
		end
	end
	table.sort(Texts)
	return Texts
end

return {
	SortedIds = SortedIds,
	SortedTexts = SortedTexts,
	SortedDueIds = SortedDueIds,
	SortedDueTexts = SortedDueTexts,
}
