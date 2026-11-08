--!strict
--!optimize 2

--[=[
	DueTimes: times at which items fall due, kept as a binary min-heap in a plain array (an empty table is an empty
	one), so a pass over what is due touches only the due items and not every item held.

	An added time is a hint and is never taken back. The owner checks each item TakeDue hands it against the item's own
	fields, and Soonest counts a time only where the caller's IsCurrent says it is still the item's; so a time left
	behind by a change costs one look when it falls due. TakeDue gives the items in heap order, which is not
	deterministic among equal times: an owner that needs an order sorts what it gets.

	Return type: A plain table with Add, TakeDue and Soonest, and the Due and DueTimes types.
	Example usage:
		DueTimes.Add(Times, Text, Clock + CheckEvery)
		for _, Text in DueTimes.TakeDue(Times, Clock) do ... end
--]=]

export type Due<Item> = { read At: number, read Item: Item }

export type DueTimes<Item> = { Due<Item> }

local HeapArity = 2

local function SiftUp<Item>(Heap: { Due<Item> }, Index: number)
	local Moving = Heap[Index]
	while Index > 1 do
		local Parent = Index // HeapArity
		local Above = Heap[Parent]
		if Above.At <= Moving.At then
			break
		end
		Heap[Index] = Above
		Index = Parent
	end
	Heap[Index] = Moving
end

local function SiftDown<Item>(Heap: { Due<Item> }, Index: number)
	local Size = #Heap
	local Moving = Heap[Index]
	while true do
		local Child = Index * HeapArity
		if Child > Size then
			break
		end
		if Child < Size and Heap[Child + 1].At < Heap[Child].At then
			Child += 1
		end
		if Moving.At <= Heap[Child].At then
			break
		end
		Heap[Index] = Heap[Child]
		Index = Child
	end
	Heap[Index] = Moving
end

local function Add<Item>(Heap: DueTimes<Item>, Item: Item, At: number)
	table.insert(Heap, { At = At, Item = Item })
	SiftUp(Heap, #Heap)
end

local function TakeFirst<Item>(Heap: { Due<Item> }): Due<Item>
	local First = Heap[1]
	local Last = table.remove(Heap) :: Due<Item>
	if #Heap > 0 then
		Heap[1] = Last
		SiftDown(Heap, 1)
	end
	return First
end

local function TakeDue<Item>(Heap: DueTimes<Item>, Clock: number): { Item }
	local Taken: { Item } = {}
	while #Heap > 0 and Heap[1].At <= Clock do
		table.insert(Taken, TakeFirst(Heap).Item)
	end
	return Taken
end

local function SoonestFrom<Item, Context>(
	Heap: { Due<Item> },
	Index: number,
	Clock: number,
	Context: Context,
	IsCurrent: (Context, Item, number) -> boolean,
	Found: number?
): number?
	local Node = Heap[Index]
	if Node == nil or (Found ~= nil and Node.At >= Found) then
		return Found
	end
	if Node.At > Clock and IsCurrent(Context, Node.Item, Node.At) then
		return Node.At
	end
	local Left = SoonestFrom(Heap, Index * HeapArity, Clock, Context, IsCurrent, Found)
	return SoonestFrom(Heap, Index * HeapArity + 1, Clock, Context, IsCurrent, Left)
end

local function Soonest<Item, Context>(
	Heap: DueTimes<Item>,
	Clock: number,
	Context: Context,
	IsCurrent: (Context, Item, number) -> boolean
): number?
	return SoonestFrom(Heap, 1, Clock, Context, IsCurrent, nil)
end

return {
	Add = Add,
	TakeDue = TakeDue,
	Soonest = Soonest,
}
