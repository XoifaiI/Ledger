--!strict
--!optimize 2

--[=[
	Cache: the one owner of the server's key cache, HCache (record sheet 6), and of finding a key's store
	and kind.

	Its size is the server's, from its first Limits recorded (ServerLimits). A new entry in a full cache pushes out
	the least recently used one, in the order CacheOrder keeps (Recency), once it is in (Recency says why), and hands
	back its resumed writer, or nil. StoreOf and StoreNamed throw where FindStore gives nil. IsReachable: opened here,
	and its MayReference holds the key; an unopened store never refuses one (CannotHold).

	Return type: A plain table of functions.
	Example usage:
		local Entry, LostResumed = Cache.CacheEntry(State, Key)
--]=]

local Names = require("../Encoding/Names")
local Recency = require("../Recency")
local Record = require("../Constants/Record")
local Shapes = require("../Shapes")

type StoreKey = Names.StoreKey
type CacheEntry = Shapes.CacheEntry
type KeyKind = Shapes.KeyKind
type Limits = Shapes.Limits
type ResumedWriter = Shapes.ResumedWriter
type ServerState = Shapes.ServerState
type StoreState = Shapes.StoreState

local KeyKinds = Record.KeyKind

local NoStoreForKey = "Cache: the key or call belongs to a store the server does not hold. The core routed it wrongly."
local NoStoreOpen = "Cache: this call is never made. A key is cached only once a store has opened."

local function KindOfKey(Key: StoreKey): KeyKind
	if string.sub(Key.Key, 1, #Record.ShardKeyPrefix) == Record.ShardKeyPrefix then
		return KeyKinds.Shard
	end
	if string.sub(Key.Key, 1, #Record.PartKeyPrefix) == Record.PartKeyPrefix then
		return KeyKinds.Part
	end
	return KeyKinds.Game
end

local function FindStore(State: ServerState, Key: StoreKey): StoreState?
	return State.Stores[Key.Store]
end

local function CannotHold(State: ServerState, Key: StoreKey): boolean
	local Store = FindStore(State, Key)
	if Store == nil then
		return false
	end
	local MayReference = Store.Setup.Build.MayReference
	if MayReference == nil then
		return false
	end
	return not MayReference({ Kind = "Short", Key = Key.Key })
end

local function IsReachable(State: ServerState, Key: StoreKey): boolean
	return FindStore(State, Key) ~= nil and not CannotHold(State, Key)
end

local function StoreNamed(State: ServerState, Name: string): StoreState
	local Store = State.Stores[Name]
	if Store == nil then
		error(NoStoreForKey)
	end
	return Store
end

local function StoreOf(State: ServerState, Key: StoreKey): StoreState
	return StoreNamed(State, Key.Store)
end

local function ServerLimits(State: ServerState): Limits
	local Recorded = State.Limits
	if Recorded == nil then
		error(NoStoreOpen)
	end
	return Recorded
end

local function FindEntry(State: ServerState, Key: StoreKey): CacheEntry?
	return State.Caches[Names.KeyText(Key)]
end

local function EvictLeastRecentlyUsed(State: ServerState): ResumedWriter?
	local Order = State.CacheOrder
	local Least = Recency.Oldest(Order)
	if Least == nil then
		return nil
	end
	Recency.Remove(Order, Least)
	local Evicted = State.Caches[Least]
	State.Caches[Least] = nil
	if Evicted == nil then
		return nil
	end
	return Evicted.Resumed
end

local function CacheEntry(State: ServerState, Key: StoreKey): (CacheEntry, ResumedWriter?)
	local Text = Names.KeyText(Key)
	local Order = State.CacheOrder
	local Found = State.Caches[Text]
	if Found ~= nil then
		Recency.Use(Order, Text)
		return Found, nil
	end
	local Created: CacheEntry = {}
	State.Caches[Text] = Created
	Recency.Use(Order, Text)
	if Order.Count <= ServerLimits(State).HorizonCacheKeys then
		return Created, nil
	end
	return Created, EvictLeastRecentlyUsed(State)
end

return {
	KindOfKey = KindOfKey,
	FindStore = FindStore,
	CannotHold = CannotHold,
	IsReachable = IsReachable,
	StoreNamed = StoreNamed,
	StoreOf = StoreOf,
	ServerLimits = ServerLimits,
	FindEntry = FindEntry,
	CacheEntry = CacheEntry,
}
