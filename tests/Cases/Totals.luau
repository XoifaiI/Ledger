--!strict
--!optimize 2

--[=[

	Totals: One rule per promise a cached total makes.

	A total is read from the MemoryStore while the sum there is inside its window and from every
	shard otherwise, one server refills a stale sum while the rest answer it, this server's own bumps
	show at once and another server's at the next refill, the key carries every part's length, and a
	store with no MemoryStore or a failing one answers as it did before. The shard layout cases stay
	in Booking, since the shards did not change.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau
--]=]

local Suite = require("../Suite")

local Ledger = require("../../src") :: any
local Engine = require("../../src/Util/Engine")
local MemoryStore = require("../../src/Core/Constants/MemoryStore")
local Shards = require("../../src/Core/Constants/Shards")
local Tally = require("../../src/Layers/Tally")

type Case = Suite.Case

local Cases = Suite.File("Totals", { "cache" })

local Reducers = Suite.Reducers
local Fault = Suite.Fault
local CACHE = Suite.Horizons.TALLY_CACHE
local CLAIM = Suite.Horizons.TALLY_CLAIM
local KEEP = Suite.Horizons.TALLY_KEEP
local SHARDS = Shards.SHARDS
local FIELD = "Coins"
local RECENT_LIMIT = 256

local function Reads(Store: any, Body: () -> ()): number
	local Before = Store.Wrapper.Spent
	Body()
	return Store.Wrapper.Spent - Before
end

local function Units(T: Case, Body: () -> ()): number
	local Before = T.Service.Units
	Body()
	return T.Service.Units - Before
end

local function Slot(Store: any, Name: string, Field: string?): string
	return Tally.Cache(Store.Wrapper.Name, Name, Field or FIELD)
end

local function Item(T: Case, Store: any, Name: string): any
	return T.Service:GetHashMap(Shards.MAP):GetAsync(Slot(Store, Name))
end

local function Plant(T: Case, Store: any, Name: string, Value: any)
	T.Service:GetHashMap(Shards.MAP):SetAsync(Slot(Store, Name), Value, KEEP)
end

local function Passing(Inner: Engine.Map, Failing: (Method: string) -> boolean): Engine.Map
	local function Check(Method: string)
		if Failing(Method) then
			error("the map is down", 0)
		end
	end

	return {
		GetAsync = function(_: any, Key: string): any
			Check("GetAsync")
			return Inner:GetAsync(Key)
		end,
		SetAsync = function(_: any, Key: string, Value: any, Expiry: number): any
			Check("SetAsync")
			return Inner:SetAsync(Key, Value, Expiry)
		end,
		UpdateAsync = function(_: any, Key: string, Transform: (any) -> any, Expiry: number): any
			Check("UpdateAsync")
			return Inner:UpdateAsync(Key, Transform, Expiry)
		end,
		RemoveAsync = function(_: any, Key: string)
			Check("RemoveAsync")
			Inner:RemoveAsync(Key)
		end,
	}
end

local function Built(T: Case, Name: string, Cache: ((Name: string) -> Engine.Map)?, Default: any?): any
	local Hook: Engine.Hook = { Open = T.Hook.Open, Budget = T.Hook.Budget, Cache = Cache }
	return Ledger.New({
		Name = Name,
		Keys = "String",
		Default = Default or Reducers.COINS,
		Reducer = Reducers.Vaulter,
		Hook = Hook,
	})
end

Cases.Case("a total is read from the shards once and then from the cache, on this server and on another", function(T: Case)
	local A = T:Vault("nodeA")
	local B = T:Vault("nodeB")
	local Bumped = Units(T, function()
		A.Store:Bump("pot", FIELD, 5):Wait()
	end)

	local First, Second, Third
	local ColdUnits = 0
	local Cold = Reads(A.Store, function()
		ColdUnits = Units(T, function()
			First = A.Store:Total("pot", FIELD):Wait()
		end)
	end)
	local WarmUnits = 0
	local Warm = Reads(A.Store, function()
		WarmUnits = Units(T, function()
			Second = A.Store:Total("pot", FIELD):Wait()
		end)
	end)
	local Other = Reads(B.Store, function()
		Third = B.Store:Total("pot", FIELD):Wait()
	end)

	T:Is("units a bump spends", Bumped, 0)
	T:Is("the total read cold", First, 5)
	T:Is("datastore reads on the cold total", Cold, SHARDS)
	T:Is("units on the cold total, a read and a refill", ColdUnits, 3)
	T:Is("the total read warm", Second, 5)
	T:Is("datastore reads on the warm total", Warm, 0)
	T:Is("units on the warm total", WarmUnits, 1)
	T:Is("the total another server reads", Third, 5)
	T:Is("datastore reads on the other server", Other, 0)
end)

Cases.Case("this server's own bumps show at once, and another server's show once the sum is refilled", function(T: Case)
	local A = T:Vault("nodeA")
	local B = T:Vault("nodeB")
	A.Store:Total("pot", FIELD):Wait()

	A.Store:Bump("pot", FIELD, 5):Wait()
	A.Store:Bump("pot", FIELD, 7):Wait()
	local Own
	local OwnReads = Reads(A.Store, function()
		Own = A.Store:Total("pot", FIELD):Wait()
	end)
	local Theirs = B.Store:Total("pot", FIELD):Wait()

	T:Advance(CACHE + 1)
	local Refilled
	local Refill = Reads(B.Store, function()
		Refilled = B.Store:Total("pot", FIELD):Wait()
	end)
	local Again = A.Store:Total("pot", FIELD):Wait()

	T:Is("the bumping server's total, at once", Own, 12)
	T:Is("datastore reads to learn that", OwnReads, 0)
	T:Is("the other server's total before a refill", Theirs, 0)
	T:Is("the other server's total once it refilled", Refilled, 12)
	T:Is("datastore reads on that refill", Refill, SHARDS)
	T:Is("the bumping server's total from the refilled sum, not counted twice", Again, 12)
end)

Cases.Case("while one server refills a stale sum the others answer it and read nothing", function(T: Case)
	local A = T:Vault("nodeA")
	local B = T:Vault("nodeB")
	local C = T:Vault("nodeC")
	A.Store:Total("pot", FIELD):Wait()
	B.Store:Bump("pot", FIELD, 5):Wait()
	T:Advance(CACHE + 1)

	local Meanwhile, MeanwhileReads, MeanwhileUnits
	local Spec = A:Fault(Fault.Reads():Only(SHARDS):Meddle(function()
		MeanwhileReads = Reads(C.Store, function()
			MeanwhileUnits = Units(T, function()
				Meanwhile = C.Store:Total("pot", FIELD):Wait()
			end)
		end)
	end))
	local RefillUnits
	local Refilled
	local RefillReads = Reads(A.Store, function()
		RefillUnits = Units(T, function()
			Refilled = A.Store:Total("pot", FIELD):Wait()
		end)
	end)
	local After = C.Store:Total("pot", FIELD):Wait()

	T:Is("the meddle fired on the last shard read", Spec.Fired, 1)
	T:Is("the total a bystander answered while the refill ran", Meanwhile, 0)
	T:Is("datastore reads the bystander spent", MeanwhileReads, 0)
	T:Is("units the bystander spent, one read and no claim", MeanwhileUnits, 1)
	T:Is("the total the refiller answered", Refilled, 5)
	T:Is("datastore reads the refiller spent", RefillReads, SHARDS)
	T:Is("units spent while the refiller ran, its read, claim and refill and the bystander's one read", RefillUnits, MemoryStore.UNIT * 2 + MemoryStore.UPDATE_UNITS * 2)
	T:Is("the bystander's total once the refill landed", After, 5)
end)

Cases.Case("a claim that ran out is taken again, and a live one is not", function(T: Case)
	local A = T:Vault("nodeA")
	local Now = T:Now()

	Plant(T, A.Store, "pot", { Sum = 7, At = Now - CACHE - 1, Claimed = Now - CLAIM - 1 })
	local Retaken
	local RetakenReads = Reads(A.Store, function()
		Retaken = A.Store:Total("pot", FIELD):Wait()
	end)
	local Written = Item(T, A.Store, "pot")

	Plant(T, A.Store, "pot", { Sum = 7, At = Now - CACHE - 1, Claimed = Now })
	local Waited
	local WaitedReads = Reads(A.Store, function()
		Waited = A.Store:Total("pot", FIELD):Wait()
	end)

	T:Is("the total once a dead claim was taken over", Retaken, 0)
	T:Is("datastore reads to take it over", RetakenReads, SHARDS)
	T:Is("the sum written back", if type(Written) == "table" then Written.Sum else nil, 0)
	T:Is("the claim, cleared by the refill", if type(Written) == "table" then Written.Claimed else "gone", nil)
	T:Is("the total answered under a live claim", Waited, 7)
	T:Is("datastore reads under a live claim", WaitedReads, 0)
end)

Cases.Case("a refill keeps a newer sum that landed while it was reading", function(T: Case)
	local A = T:Vault("nodeA")
	A.Store:Total("pot", FIELD):Wait()
	T:Advance(CACHE + 1)

	local Spec = A:Fault(Fault.Reads():Only(SHARDS):Meddle(function()
		Plant(T, A.Store, "pot", { Sum = 99, At = T:Now() + 1 })
	end))
	local Own = A.Store:Total("pot", FIELD):Wait()
	local Next = A.Store:Total("pot", FIELD):Wait()

	T:Is("the meddle fired on the last shard read", Spec.Fired, 1)
	T:Is("the refiller's own answer, from the shards it read", Own, 0)
	T:Is("the total once the refill met the newer sum", Next, 99)
end)

Cases.Case("a dropped refill leaves the total right and caches nothing", function(T: Case)
	local Store = Built(T, "CaseTotalsDrop", function(Name: string): Engine.Map
		return Passing(T.Hook.Cache(Name), function(Method: string): boolean
			return Method == "UpdateAsync"
		end)
	end)
	Store:Bump("pot", FIELD, 5):Wait()

	local First, Second
	local Cold = Reads(Store, function()
		First = Store:Total("pot", FIELD):Wait()
	end)
	local Absent = Item(T, Store, "pot")
	local Again = Reads(Store, function()
		Second = Store:Total("pot", FIELD):Wait()
	end)

	T:Is("the first total", First, 5)
	T:Is("datastore reads on the first", Cold, SHARDS)
	T:Is("the item after a refill that dropped", Absent, nil)
	T:Is("the second total", Second, 5)
	T:Is("datastore reads on the second", Again, SHARDS)
	T:Warns("it said the map did not answer", "did not answer", 1)
end)

Cases.Case("MaxAge answers from this server with no call at all", function(T: Case)
	local A = T:Vault("nodeA")
	A.Store:Bump("pot", FIELD, 5):Wait()
	A.Store:Total("pot", FIELD):Wait()

	local Held
	local Read = Reads(A.Store, function()
		Held = Units(T, function()
			T:Is("the total answered in process", A.Store:Total("pot", FIELD, 30):Wait(), 5)
		end)
	end)

	A.Store:Bump("pot", FIELD, 2):Wait()
	local Bumped = Units(T, function()
		T:Is("the total answered in process after a bump", A.Store:Total("pot", FIELD, 30):Wait(), 7)
	end)

	T:Advance(31)
	local Aged = Units(T, function()
		T:Is("the total once the copy is older than asked", A.Store:Total("pot", FIELD, 30):Wait(), 7)
	end)

	T:Is("datastore reads for the in process answer", Read, 0)
	T:Is("units for the in process answer", Held, 0)
	T:Is("units for the in process answer after a bump", Bumped, 0)
	T:Is("units once the copy aged out, one cache read", Aged, 1)
	T:Throws("a MaxAge below zero", function()
		A.Store:Total("pot", FIELD, -1)
	end)
end)

Cases.Case("a store with no MemoryStore reads every total from its shards and says so once at build", function(T: Case)
	local Store = Built(T, "CaseTotalsBare", nil)
	Store:Bump("pot", FIELD, 5):Wait()

	local First, Second
	local Cold = Reads(Store, function()
		First = Store:Total("pot", FIELD):Wait()
	end)
	local Again = Reads(Store, function()
		Second = Store:Total("pot", FIELD):Wait()
	end)

	T:Is("the first total", First, 5)
	T:Is("the second total", Second, 5)
	T:Is("datastore reads on the first", Cold, SHARDS)
	T:Is("datastore reads on the second", Again, SHARDS)
	T:Warns("it said the store has no MemoryStore", "no MemoryStore", 1)
end)

Cases.Case("a store whose MemoryStore fails every call answers every total as it did before", function(T: Case)
	local Store = Built(T, "CaseTotalsDown", function(Name: string): Engine.Map
		return Passing(T.Hook.Cache(Name), function(_Method: string): boolean
			return true
		end)
	end)
	local Ok = Store:Bump("pot", FIELD, 5):Wait()

	local First, Second
	local Cold = Reads(Store, function()
		First = Store:Total("pot", FIELD):Wait()
	end)
	local Again = Reads(Store, function()
		Second = Store:Total("pot", FIELD):Wait()
	end)

	T:Ok("the bump", Ok)
	T:Is("the first total", First, 5)
	T:Is("the second total", Second, 5)
	T:Is("datastore reads on the first", Cold, SHARDS)
	T:Is("datastore reads on the second", Again, SHARDS)
	T:Warns("it said the map did not answer, once for the whole burst", "did not answer", 1)
end)

Cases.Case("one shard that cannot be read still refuses the whole total, and nothing is cached from it", function(T: Case)
	local A = T:Vault("nodeA")
	A:NoRetries()
	A.Store:Bump("pot", FIELD, 5):Wait()

	A:Fault(Fault.Reads():OnKey(Tally.Shard("pot", 3)))
	local Sum, Why = A.Store:Total("pot", FIELD):Wait()
	local Cached = Item(T, A.Store, "pot")

	A:Healed()
	local Healed
	local Read = Reads(A.Store, function()
		Healed = A.Store:Total("pot", FIELD):Wait()
	end)

	T:Is("the total with a shard unreadable", Sum, nil)
	T:Is("the reason", Why, Suite.Reasons.Unresolved)
	T:Is("the item after the refusal", Cached, nil)
	T:Is("the total once the shard reads again", Healed, 5)
	T:Is("datastore reads to learn that", Read, SHARDS)
end)

Cases.Case("two stores with a tally of the same name keep separate totals", function(T: Case)
	local A = T:Vault("nodeA")
	local Other = T:Store({ Default = Reducers.COINS, Reducer = Reducers.Vaulter, Data = "CaseTotalsOther", Field = FIELD })

	A.Store:Bump("pot", FIELD, 5):Wait()
	Other.Store:Bump("pot", FIELD, 7):Wait()

	T:Is("the first store's total", A.Store:Total("pot", FIELD):Wait(), 5)
	T:Is("the other store's total", Other.Store:Total("pot", FIELD):Wait(), 7)
	T:Is("the first store's total again, from the cache", A.Store:Total("pot", FIELD):Wait(), 5)
end)

Cases.Case("a cache key carries every part's length, so a colon in a name cannot read as another, and a long one is digested", function(T: Case)
	local Long = string.rep("f", 120)
	local Store = Built(T, "CaseTotalsKeys", T.Hook.Cache, { Coins = 0, ["Coins:X"] = 0, X = 0, [Long] = 0 })

	Store:Bump("pot:Coins", "X", 5):Wait()
	Store:Bump("pot", "Coins:X", 7):Wait()
	Store:Bump("pot", Long, 9):Wait()

	T:Is("the tally named with a colon", Store:Total("pot:Coins", "X"):Wait(), 5)
	T:Is("the field named with a colon", Store:Total("pot", "Coins:X"):Wait(), 7)
	T:Is("the tally on a long field, through a digested key", Store:Total("pot", Long):Wait(), 9)
	T:Is("the long field's key, at most the cap", #Slot(Store, "pot", Long) <= MemoryStore.MAX_KEY, true)
	T:Is("the two keys with a colon, apart", Slot(Store, "pot:Coins", "X") ~= Slot(Store, "pot", "Coins:X"), true)
	T:Is("the long field's total again, from the cache", Store:Total("pot", Long):Wait(), 9)
end)

Cases.Case("a bump in the same second as another server's refill shows at the next refill, and never twice", function(T: Case)
	local A = T:Vault("nodeA")
	local B = T:Vault("nodeB")
	A.Store:Total("pot", FIELD):Wait()
	B.Store:Total("pot", FIELD):Wait()

	A.Store:Bump("pot", FIELD, 5):Wait()
	local OwnAtOnce = A.Store:Total("pot", FIELD):Wait()
	T:Advance(CACHE + 1)
	local Refilled = B.Store:Total("pot", FIELD):Wait()
	local Theirs = A.Store:Total("pot", FIELD):Wait()

	A.Store:Bump("pot", FIELD, 3):Wait()
	local Lagging = A.Store:Total("pot", FIELD):Wait()
	T:Advance(CACHE + 1)
	local Caught = A.Store:Total("pot", FIELD):Wait()

	T:Is("an own bump in the second of an own refill, at once", OwnAtOnce, 5)
	T:Is("the other server's refill", Refilled, 5)
	T:Is("the bumping server on the other's sum, not counted twice", Theirs, 5)
	T:Is("an own bump in the second of another's refill, held back", Lagging, 5)
	T:Is("the same bump once the sum is refilled", Caught, 8)
end)

Cases.Case("own bumps are kept for the keep window and the tallies a server remembers are capped", function(T: Case)
	local A = T:Vault("nodeA")
	A.Store:Bump("pot", FIELD, 5):Wait()
	local Kept = #A.Store.Recent:Get(Slot(A.Store, "pot")).Bumps
	T:Advance(KEEP + 1)
	A.Store:Total("pot", FIELD):Wait()
	local Pruned = #A.Store.Recent:Get(Slot(A.Store, "pot")).Bumps

	for Index = 1, RECENT_LIMIT + 20 do
		A.Store:Total(`t{Index}`, FIELD, 0):Wait()
	end

	T:Is("own bumps kept right after bumping", Kept, 1)
	T:Is("own bumps once the keep window passed", Pruned, 0)
	T:Is("tallies remembered, capped", A.Store.Recent.Count, RECENT_LIMIT)
	T:Is("the first tally, touched longest ago, is the one forgotten", A.Store.Recent:Get(Slot(A.Store, "pot")), nil)
	T:Is("the newest tally is still remembered", A.Store.Recent:Get(Slot(A.Store, `t{RECENT_LIMIT + 20}`)) ~= nil, true)
end)

return Cases
