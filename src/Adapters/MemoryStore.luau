--!strict
--!optimize 2

--[=[

	MemoryStore: Makes one call to a MemoryStore map, and answers a miss when the call fails.

	Each function answers as pcall does: true and the value, or false and the error. Everything Ledger
	keeps in MemoryStore is advice, so nothing here retries and a miss means carry on without it.
	MISSES misses in a row stop the calls to that map for BREAKER seconds, and those calls answer false
	and nil without being made. Any answer clears the count. Each map has its own cache, so one map
	that breaks leaves the others alone.

	Return type: A table with New, Get, Set, Update, Remove, MISSES and BREAKER.
	Example usage:
		local MemoryStore = require("./MemoryStore")
		local Cache = MemoryStore.New(Map)
		local Ok, Value = MemoryStore.Get(Cache, Now, "t/Gold")
--]=]

export type Map = {
	GetAsync: (self: any, Key: string) -> unknown,
	SetAsync: (self: any, Key: string, Value: unknown, Expiry: number) -> unknown,
	UpdateAsync: (self: any, Key: string, Transform: (Current: unknown) -> unknown, Expiry: number) -> unknown,
	RemoveAsync: (self: any, Key: string) -> (),
}

export type Cache = {
	read Map: Map,
	Row: number,
	Quiet: number,
}

local MISSES = 3
local BREAKER = 120

local function Settle(Cache: Cache, Now: number, Ok: boolean, Value: unknown): (boolean, unknown)
	if Ok then
		Cache.Row = 0
		return true, Value
	end
	Cache.Row += 1
	if Cache.Row >= MISSES then
		Cache.Quiet = Now + BREAKER
	end
	return false, Value
end

local function New(Map: Map): Cache
	return { Map = Map, Row = 0, Quiet = 0 }
end

local function Get(Cache: Cache, Now: number, Key: string): (boolean, unknown)
	if Now < Cache.Quiet then
		return false, nil
	end
	return Settle(Cache, Now, pcall(Cache.Map.GetAsync, Cache.Map, Key))
end

local function Set(Cache: Cache, Now: number, Key: string, Value: unknown, Expiry: number): (boolean, unknown)
	if Now < Cache.Quiet then
		return false, nil
	end
	return Settle(Cache, Now, pcall(Cache.Map.SetAsync, Cache.Map, Key, Value, Expiry))
end

local function Update(Cache: Cache, Now: number, Key: string, Transform: (Current: unknown) -> unknown, Expiry: number): (boolean, unknown)
	if Now < Cache.Quiet then
		return false, nil
	end
	return Settle(Cache, Now, pcall(Cache.Map.UpdateAsync, Cache.Map, Key, Transform, Expiry))
end

local function Remove(Cache: Cache, Now: number, Key: string): (boolean, unknown)
	if Now < Cache.Quiet then
		return false, nil
	end
	return Settle(Cache, Now, pcall(Cache.Map.RemoveAsync, Cache.Map, Key))
end

return table.freeze({
	New = New,
	Get = Get,
	Set = Set,
	Update = Update,
	Remove = Remove,
	MISSES = MISSES,
	BREAKER = BREAKER,
})
