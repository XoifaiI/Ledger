--!strict
--!optimize 2

--[=[

	Lru: A bounded map that forgets what was touched longest ago.

	Entries sit on a doubly linked list in the order they were last touched, so a touch and an
	eviction each cost the same however many entries there are. Get touches, Put touches or adds, and
	adding past the limit drops the head of the list first. New hands back a loose one, since nothing
	it is given names the entry type, and the annotation on whatever holds it is what fixes that.

	Return type: A table with New. The type is Lru.
	Example usage:
		local Lru = require("./Lru")
		local Recent: Lru.Lru<Entry> = Lru.New(256)
		local Held = Recent:Get("pot") or Recent:Put("pot", Fresh)
--]=]

type Node = {
	Key: string,
	Value: any,
	Previous: Node?,
	Next: Node?,
}

type LruImpl<T> = {
	__index: LruImpl<T>,
	Get: (self: Lru<T>, Key: string) -> T?,
	Put: (self: Lru<T>, Key: string, Value: T) -> T,
}

export type Lru<T> = setmetatable<{
	Limit: number,
	Count: number,
	Nodes: { [string]: Node },
	Head: Node?,
	Tail: Node?,
}, LruImpl<T>>

local Lru = {} :: LruImpl<any>
Lru.__index = Lru

local function Unlink<T>(self: Lru<T>, Node: Node)
	local Previous = Node.Previous
	local Following = Node.Next

	if Previous ~= nil then
		Previous.Next = Following
	else
		self.Head = Following
	end

	if Following ~= nil then
		Following.Previous = Previous
	else
		self.Tail = Previous
	end

	Node.Previous = nil
	Node.Next = nil
end

local function Append<T>(self: Lru<T>, Node: Node)
	local Tail = self.Tail
	Node.Previous = Tail
	if Tail ~= nil then
		Tail.Next = Node
	else
		self.Head = Node
	end
	self.Tail = Node
end

local function New(Limit: number): Lru<any>
	assert(type(Limit) == "number" and Limit >= 1 and Limit == Limit // 1, "an Lru needs a whole number of entries to keep, at least one")

	return setmetatable({
		Limit = Limit,
		Count = 0,
		Nodes = {},
		Head = nil,
		Tail = nil,
	}, Lru) :: any
end

function Lru.Get<T>(self: Lru<T>, Key: string): T?
	local Node = self.Nodes[Key]
	if Node == nil then
		return nil
	end

	if self.Tail ~= Node then
		Unlink(self, Node)
		Append(self, Node)
	end
	return Node.Value
end

function Lru.Put<T>(self: Lru<T>, Key: string, Value: T): T
	local Node = self.Nodes[Key]
	if Node ~= nil then
		Node.Value = Value
		if self.Tail ~= Node then
			Unlink(self, Node)
			Append(self, Node)
		end
		return Value
	end

	if self.Count >= self.Limit then
		local Oldest = self.Head :: Node
		Unlink(self, Oldest)
		self.Nodes[Oldest.Key] = nil
		self.Count -= 1
	end

	local Fresh: Node = { Key = Key, Value = Value }
	self.Nodes[Key] = Fresh
	Append(self, Fresh)
	self.Count += 1
	return Value
end

table.freeze(Lru)

return table.freeze({
	New = New,
})
