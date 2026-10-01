--!strict
--!optimize 2

--[=[

	MemoryStore: Plumbing. One call to a MemoryStore map, answered as pcall answers.

	Nothing retries. Limits.MISSES misses in a row stop the calls to that map for Windows.BREAKER
	seconds, and those calls answer false. Any answer clears the count. Open gives back the one
	cache of a hash map's name. Every call of this server to that map shares its breaker.

	Return type: The Cache class, with New, Open and the methods Get, Set, Update and Remove.
	Example usage:
		local Ok, Value = Cache:Get(Now, "t/Gold")
--]=]

local MemoryStoreService = game:GetService("MemoryStoreService")

local Limits = require("../Core/Constants/Limits")
local Windows = require("../Core/Constants/Windows")

export type Map = {
	GetAsync: (self: any, Key: string) -> unknown,
	SetAsync: (self: any, Key: string, Value: unknown, Expiry: number) -> unknown,
	UpdateAsync: (self: any, Key: string, Transform: (Current: unknown) -> unknown, Expiry: number) -> unknown,
	RemoveAsync: (self: any, Key: string) -> (),
}

type CacheImpl = {
	__index: CacheImpl,
	New: (Map: Map) -> Cache,
	Open: (Name: string) -> Cache,
	Get: (self: Cache, Now: number, Key: string) -> (boolean, unknown),
	Set: (self: Cache, Now: number, Key: string, Value: unknown, Expiry: number) -> (boolean, unknown),
	Update: (self: Cache, Now: number, Key: string, Transform: (Current: unknown) -> unknown, Expiry: number) -> (boolean, unknown),
	Remove: (self: Cache, Now: number, Key: string) -> (boolean, unknown),
}

type Data = {
	read Map: Map,
	Row: number,
	Quiet: number,
}

export type Cache = setmetatable<Data, CacheImpl>

local Cache = {} :: CacheImpl
Cache.__index = Cache

local Opened: { [string]: Cache } = {}

local function Settle(Held: Data, Now: number, Ok: boolean, Value: unknown): (boolean, unknown)
	if Ok then
		Held.Row = 0
		return true, Value
	end
	Held.Row += 1
	if Held.Row >= Limits.MISSES then
		Held.Quiet = Now + Windows.BREAKER
	end
	return false, Value
end

function Cache.New(Map: Map): Cache
	local Fresh: Data = { Map = Map, Row = 0, Quiet = 0 }
	return setmetatable(Fresh, Cache)
end

function Cache.Open(Name: string): Cache
	local Found = Opened[Name]
	if Found == nil then
		Found = Cache.New(MemoryStoreService:GetHashMap(Name) :: any)
		Opened[Name] = Found
	end
	return Found
end

function Cache.Get(self: Cache, Now: number, Key: string): (boolean, unknown)
	if Now < self.Quiet then
		return false, nil
	end
	return Settle(self, Now, pcall(self.Map.GetAsync, self.Map, Key))
end

function Cache.Set(self: Cache, Now: number, Key: string, Value: unknown, Expiry: number): (boolean, unknown)
	if Now < self.Quiet then
		return false, nil
	end
	return Settle(self, Now, pcall(self.Map.SetAsync, self.Map, Key, Value, Expiry))
end

function Cache.Update(self: Cache, Now: number, Key: string, Transform: (Current: unknown) -> unknown, Expiry: number): (boolean, unknown)
	if Now < self.Quiet then
		return false, nil
	end
	return Settle(self, Now, pcall(self.Map.UpdateAsync, self.Map, Key, Transform, Expiry))
end

function Cache.Remove(self: Cache, Now: number, Key: string): (boolean, unknown)
	if Now < self.Quiet then
		return false, nil
	end
	return Settle(self, Now, pcall(self.Map.RemoveAsync, self.Map, Key))
end

return Cache
