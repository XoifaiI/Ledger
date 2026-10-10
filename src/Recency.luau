--!strict
--!optimize 2

--[=[
	Recency: texts in the order they were last used, for a table that lets its least recently used text go when it
	is full (the key cache, the shown table, the remembered states of keys not served here, the sent names).

	It is a doubly linked list: Links holds each text's older and newer neighbour, First the least recently used text
	and Last the most. A use moves a text to Last, so every operation is O(1) and the order is exact. Count is the
	number of texts held, kept as they come and go.

	An owner adds its new text before it lets the oldest go (Count passes its cap by one, then comes back). A Luau map
	whose live keys peak at a power of two, such as a cap of 4,096, rehashes on every insert that follows a removal:
	measured 95 us an insert at 4,096 keys against 0.1 us at 4,097 (luau 0.741 --codegen -O2), so the order of the two
	steps is kept in every owner.

	Return type: A plain table of functions, and the Recency and Link types.
	Example usage:
		local Order = Recency.New()
		Recency.Use(Order, Text)
		local Least = Recency.Oldest(Order)
--]=]

export type Link = { Older: string?, Newer: string? }

export type Recency = {
	Links: { [string]: Link },
	First: string?,
	Last: string?,
	Count: number,
}

local function New(): Recency
	return { Links = {}, First = nil, Last = nil, Count = 0 }
end

local function NewLink(Older: string?): Link
	return { Older = Older, Newer = nil }
end

local function Unlink(Order: Recency, Link: Link)
	local Older = Link.Older
	local Newer = Link.Newer
	if Older == nil then
		Order.First = Newer
	else
		Order.Links[Older].Newer = Newer
	end
	if Newer == nil then
		Order.Last = Older
	else
		Order.Links[Newer].Older = Older
	end
end

local function Use(Order: Recency, Text: string)
	local Newest = Order.Last
	if Newest == Text then
		return
	end
	local Held = Order.Links[Text]
	if Held == nil then
		Order.Links[Text] = NewLink(Newest)
		Order.Count += 1
	else
		Unlink(Order, Held)
		Newest = Order.Last
		Held.Older = Newest
		Held.Newer = nil
	end
	if Newest == nil then
		Order.First = Text
	else
		Order.Links[Newest].Newer = Text
	end
	Order.Last = Text
end

local function Remove(Order: Recency, Text: string)
	local Link = Order.Links[Text]
	if Link == nil then
		return
	end
	Unlink(Order, Link)
	Order.Links[Text] = nil
	Order.Count -= 1
end

local function Oldest(Order: Recency): string?
	return Order.First
end

return {
	New = New,
	Use = Use,
	Remove = Remove,
	Oldest = Oldest,
}
