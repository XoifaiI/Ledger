--!strict
--!optimize 2

--[=[

	Lru: A bounded map that forgets what was touched longest ago.

	Entries sit on a doubly linked list in the order they were last touched, so a touch and an eviction
	each cost O(1). Get touches, and Put touches or adds. Adding past the limit drops the entry touched
	longest ago first. New gives back a loose cache, so name the entry type on the local that holds it.

	Return type: A table with New, Get, Put and Clear.
	Example usage:
		local Lru = require("./Lru")
		local Horizons: Lru.Lru<number> = Lru.New(4096)
		Lru.Put(Horizons, "42", 1700000000)
--]=]

type Node = {
	Key: string,
	Value: any,
	Previous: Node?,
	Next: Node?,
}

export type Lru<T> = {
	read Limit: number,
	Count: number,
	Nodes: { [string]: Node },
	Head: Node?,
	Tail: Node?,
}

local function Unlink(Cache: Lru<any>, Entry: Node)
	local Previous, Following = Entry.Previous, Entry.Next
	if Previous then
		Previous.Next = Following
	else
		Cache.Head = Following
	end
	if Following then
		Following.Previous = Previous
	else
		Cache.Tail = Previous
	end
	Entry.Previous = nil
	Entry.Next = nil
end

local function Append(Cache: Lru<any>, Entry: Node)
	local Tail = Cache.Tail
	Entry.Previous = Tail
	if Tail then
		Tail.Next = Entry
	else
		Cache.Head = Entry
	end
	Cache.Tail = Entry
end

local function Touch(Cache: Lru<any>, Entry: Node)
	if Cache.Tail == Entry then
		return
	end
	Unlink(Cache, Entry)
	Append(Cache, Entry)
end

local function New(Limit: number): Lru<any>
	if not (Limit >= 1 and Limit % 1 == 0) then
		error(`Lru: the limit {Limit} is not a whole number of at least 1`, 2)
	end
	return { Limit = Limit, Count = 0, Nodes = {}, Head = nil, Tail = nil }
end

local function Get<T>(Cache: Lru<T>, Key: string): T?
	local Entry = Cache.Nodes[Key]
	if Entry == nil then
		return nil
	end
	Touch(Cache, Entry)
	return Entry.Value
end

local function Put<T>(Cache: Lru<T>, Key: string, Value: T): T
	local Entry = Cache.Nodes[Key]
	if Entry then
		Entry.Value = Value
		Touch(Cache, Entry)
		return Value
	end
	local Oldest = Cache.Head
	if Oldest and Cache.Count >= Cache.Limit then
		Unlink(Cache, Oldest)
		Cache.Nodes[Oldest.Key] = nil
		Cache.Count -= 1
	end
	local Fresh: Node = { Key = Key, Value = Value }
	Cache.Nodes[Key] = Fresh
	Append(Cache, Fresh)
	Cache.Count += 1
	return Value
end

local function Clear<T>(Cache: Lru<T>)
	table.clear(Cache.Nodes)
	Cache.Head = nil
	Cache.Tail = nil
	Cache.Count = 0
end

return table.freeze({
	New = New,
	Get = Get,
	Put = Put,
	Clear = Clear,
})
