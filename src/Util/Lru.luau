--!strict
--!optimize 2

--[=[
	Lru: Plumbing. A bounded map that forgets what was touched longest ago.

	Get touches as well as Put, each in O(1). Put gives back the key it forgot to make room, so a
	caller can mark it elsewhere. New makes an Lru of any, so name the entry type on the local that
	holds it.

	Return type: The Lru class.
	Example usage:
		local Horizons: Lru.Lru<number> = Lru.New(4096)
--]=]

type Node = {
	Key: string,
	Value: any,
	Previous: Node?,
	Next: Node?,
}

type LruImpl<T> = {
	__index: LruImpl<T>,
	New: (Limit: number) -> Lru<T>,
	Get: (self: Lru<T>, Key: string) -> T?,
	Put: (self: Lru<T>, Key: string, Value: T) -> string?,
	Clear: (self: Lru<T>) -> (),
}

type Data = {
	read Limit: number,
	Count: number,
	Nodes: { [string]: Node },
	Head: Node?,
	Tail: Node?,
}

export type Lru<T> = setmetatable<Data, LruImpl<T>>

local Lru = {} :: LruImpl<any>
Lru.__index = Lru

local function Unlink(Cache: Data, Entry: Node)
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

local function Append(Cache: Data, Entry: Node)
	local Tail = Cache.Tail
	Entry.Previous = Tail
	if Tail then
		Tail.Next = Entry
	else
		Cache.Head = Entry
	end
	Cache.Tail = Entry
end

local function Touch(Cache: Data, Entry: Node)
	if Cache.Tail ~= Entry then
		Unlink(Cache, Entry)
		Append(Cache, Entry)
	end
end

function Lru.New(Limit: number): Lru<any>
	if not (Limit >= 1 and Limit % 1 == 0) then
		error(`Lru: the limit {Limit} is not a whole number of at least 1`, 2)
	end
	local Fresh: Data = { Limit = Limit, Count = 0, Nodes = {} }
	return setmetatable(Fresh, Lru)
end

function Lru.Get<T>(self: Lru<T>, Key: string): T?
	local Entry = self.Nodes[Key]
	if Entry == nil then
		return nil
	end
	Touch(self, Entry)
	return Entry.Value
end

function Lru.Put<T>(self: Lru<T>, Key: string, Value: T): string?
	local Entry = self.Nodes[Key]
	if Entry then
		Entry.Value = Value
		Touch(self, Entry)
		return nil
	end
	local Oldest = self.Head
	local Forgot: string? = nil
	if Oldest and self.Count >= self.Limit then
		Unlink(self, Oldest)
		self.Nodes[Oldest.Key] = nil
		self.Count -= 1
		Forgot = Oldest.Key
	end
	local Fresh: Node = { Key = Key, Value = Value }
	self.Nodes[Key] = Fresh
	Append(self, Fresh)
	self.Count += 1
	return Forgot
end

function Lru.Clear<T>(self: Lru<T>)
	table.clear(self.Nodes)
	self.Head = nil
	self.Tail = nil
	self.Count = 0
end

return Lru
