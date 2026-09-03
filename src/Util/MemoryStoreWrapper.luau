--!strict
--!optimize 2

--[=[

	MemoryStoreWrapper: Calls a MemoryStore map once, and answers a miss when the call fails.

	Nothing here retries, since a wait on a cache stalls the thing it was meant to speed up, and a
	caller treats a miss as the map being absent. Each key has its own queue, so two writes to one
	key from this server land in order. A miss is counted, and said out loud at most once a window.
	A few misses in a row stop the calls for one BREAKER, so an outage does not add a failed call to
	every operation on every server. Any answer clears the count, so one throttled key cannot stop
	the calls for a map that is still answering, and each map has its own wrapper, so one map
	breaking leaves the others alone.

	Return type: A table with New and Misses.
	Example usage:
		local Wrapper = require("./MemoryStoreWrapper")
		local Leases = Wrapper.New("Ledger_Lease", Scheduler, Hook)
		local Ok, Value = Leases:GetAsync("tx:1")
--]=]

local Engine = require("./Engine")
local Windows = require("../Core/Constants/Windows")

local NoYield = require("./NoYield")
local ThreadQueue = require("./ThreadQueue")

type ThreadQueue = ThreadQueue.ThreadQueue
type Transform = (any) -> any

type MemoryStoreWrapperImpl = {
	__index: MemoryStoreWrapperImpl,
	New: (Name: string, Scheduler: Engine.Scheduler, Hook: Engine.Hook) -> MemoryStoreWrapper,
	GetMap: (self: MemoryStoreWrapper) -> Engine.Map,
	Miss: (self: MemoryStoreWrapper, Err: any) -> (),
	AttemptAsync: (self: MemoryStoreWrapper, Key: string, Operation: (Map: Engine.Map) -> ...any) -> (boolean, ...any),
	GetAsync: (self: MemoryStoreWrapper, Key: string) -> (boolean, any),
	SetAsync: (self: MemoryStoreWrapper, Key: string, Value: any, Expiry: number) -> boolean,
	UpdateAsync: (self: MemoryStoreWrapper, Key: string, Transform: Transform, Expiry: number) -> (boolean, any),
	RemoveAsync: (self: MemoryStoreWrapper, Key: string) -> boolean,
}

export type MemoryStoreWrapper = setmetatable<{
	Name: string,
	Scheduler: Engine.Scheduler,
	Hook: Engine.Hook,
	Spent: number,
	Missed: number,
	Counted: number,
	Said: number,
	Row: number,
	Quiet: number,
	Direct: boolean?,
	Map: Engine.Map?,
	Queues: { [string]: ThreadQueue },
}, MemoryStoreWrapperImpl>

local SAY_EVERY = Windows.AUTOSAVE
local MISSES_ALLOWED = 3

local MemoryStoreWrapper = {} :: MemoryStoreWrapperImpl
MemoryStoreWrapper.__index = MemoryStoreWrapper

function MemoryStoreWrapper.New(Name: string, Scheduler: Engine.Scheduler, Hook: Engine.Hook): MemoryStoreWrapper
	assert(Hook.Cache ~= nil, `a MemoryStore wrapper for '{Name}' needs a hook with a Cache, and this hook has none`)

	return setmetatable({
		Name = Name,
		Scheduler = Scheduler,
		Hook = Hook,
		Spent = 0,
		Missed = 0,
		Counted = 0,
		Said = 0,
		Row = 0,
		Quiet = 0,
		Queues = {},
	}, MemoryStoreWrapper) :: MemoryStoreWrapper
end

function MemoryStoreWrapper.GetMap(self: MemoryStoreWrapper): Engine.Map
	local Own = self.Map
	if Own ~= nil then
		return Own
	end

	local Cache = self.Hook.Cache
	assert(Cache ~= nil, `the hook behind '{self.Name}' lost its Cache after the wrapper was built`)
	return Cache(self.Name)
end

function MemoryStoreWrapper.Miss(self: MemoryStoreWrapper, Err: any)
	self.Missed += 1
	self.Counted += 1

	local Now = self.Scheduler.Now()
	self.Row += 1
	if self.Row >= MISSES_ALLOWED then
		self.Row = 0
		self.Quiet = Now + Windows.BREAKER
	end

	if Now - self.Said < SAY_EVERY then
		return
	end

	warn(`Ledger: MemoryStore did not answer for '{self.Name}', so this server carried on without it. {self.Counted} miss(es) since the last of these: {tostring(Err)}`)
	self.Counted = 0
	self.Said = Now
end

function MemoryStoreWrapper.AttemptAsync(self: MemoryStoreWrapper, Key: string, Operation: (Map: Engine.Map) -> ...any): (boolean, ...any)
	assert(type(Key) == "string", "a MemoryStore call was queued under something that is not a key")

	if self.Scheduler.Now() < self.Quiet then
		return false
	end

	local function Once(): (boolean, ...any)
		self.Spent += 1
		local Result = table.pack(pcall(function(): ...any
			return Operation(self:GetMap())
		end))
		if not Result[1] then
			self:Miss(Result[2])
			return false
		end
		self.Row = 0
		return true, table.unpack(Result, 2, Result.n)
	end

	if self.Direct then
		return Once()
	end

	local Result = table.pack(pcall(ThreadQueue.Keyed, self.Queues, self.Scheduler, Key, Once))
	if not Result[1] then
		self:Miss(Result[2])
		return false
	end
	return table.unpack(Result, 2, Result.n)
end

function MemoryStoreWrapper.GetAsync(self: MemoryStoreWrapper, Key: string): (boolean, any)
	return self:AttemptAsync(Key, function(Map: Engine.Map): any
		return Map:GetAsync(Key)
	end)
end

function MemoryStoreWrapper.SetAsync(self: MemoryStoreWrapper, Key: string, Value: any, Expiry: number): boolean
	return (self:AttemptAsync(Key, function(Map: Engine.Map)
		Map:SetAsync(Key, Value, Expiry)
	end))
end

function MemoryStoreWrapper.UpdateAsync(self: MemoryStoreWrapper, Key: string, Transform: Transform, Expiry: number): (boolean, any)
	return self:AttemptAsync(Key, function(Map: Engine.Map): any
		return Map:UpdateAsync(Key, function(Current: any): any
			return NoYield.Run(Transform, Current)
		end, Expiry)
	end)
end

function MemoryStoreWrapper.RemoveAsync(self: MemoryStoreWrapper, Key: string): boolean
	return (self:AttemptAsync(Key, function(Map: Engine.Map)
		Map:RemoveAsync(Key)
	end))
end

table.freeze(MemoryStoreWrapper)

return table.freeze({
	New = MemoryStoreWrapper.New,
	Misses = MISSES_ALLOWED,
})
