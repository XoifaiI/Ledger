--!strict
--!optimize 2

--[=[

	Follows: One rule per promise a copy of a key makes.

	A Peek with a MaxAge answers this server's copy while it is young, the shared item next, and the
	record only through a claim. One server refills a stale item while the rest answer it. A cold
	fleet reads the record once. A follower ticks, backs off while nothing moves, and pushes once
	when it does. A write on this server shows in its own copy at once. A map that stops answering
	holds a follower to its copy. The copy carries the game's fields and none of Ledger's own.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau follows
--]=]

local Suite = require("../Suite")

local Ledger = require("../../src") :: any
local Engine = require("../../src/Util/Engine")
local Follows = require("../../src/Core/Constants/Follows")
local MemoryStore = require("../../src/Core/Constants/MemoryStore")
local Mark = require("../../src/Encode/Mark")

type Case = Suite.Case
type Fixture = Suite.Fixture

local Cases = Suite.File("Follows", { "cache" })

local Reducers = Suite.Reducers
local Fault = Suite.Fault
local Reasons = Suite.Reasons
local CACHE = Suite.Horizons.TALLY_CACHE
local CLAIM = Suite.Horizons.TALLY_CLAIM
local KEEP = Suite.Horizons.TALLY_KEEP
local SLACK = Suite.Horizons.COPY_SLACK
local STALE = CACHE + SLACK + 1
local FOLLOW = Suite.Horizons.FOLLOW
local FOLLOW_CAP = Suite.Horizons.FOLLOW_CAP
local AGE = 30
local KEY = "config"

local function Reads(Held: Fixture, Body: () -> ()): number
	local Before = Held.Store.Wrapper.Spent
	Body()
	return Held.Store.Wrapper.Spent - Before
end

local function Units(T: Case, Body: () -> ()): number
	local Before = T.Service.Units
	Body()
	return T.Service.Units - Before
end

local function Slot(Held: Fixture, Key: string): string
	return Mark.Cached({ Held.Store.Wrapper.Name, Key })
end

local function Item(T: Case, Held: Fixture, Key: string): any
	return T.Service:GetHashMap(Follows.MAP):GetAsync(Slot(Held, Key))
end

local function Plant(T: Case, Held: Fixture, Key: string, Value: any)
	T.Service:GetHashMap(Follows.MAP):SetAsync(Slot(Held, Key), Value, KEEP)
end

local function Gold(Held: Fixture, Key: string, MaxAge: number?): (number?, any)
	local State, Why = Held.Store:Peek(Key, MaxAge):Wait()
	return if type(State) == "table" then State.Gold else nil, Why
end

local function Fund(Held: Fixture, Key: string, Amount: number): boolean
	return (Held.Store:Edit(Key, "Fund", { Amount = Amount }):Wait())
end

local function Broken(T: Case): Engine.Hook
	return {
		Open = T.Hook.Open,
		Budget = T.Hook.Budget,
		Cache = function(_Name: string): Engine.Map
			return {
				GetAsync = function(_: any, _Key: string): any
					error("the map is down", 0)
				end,
				SetAsync = function(_: any, _Key: string, _Value: any, _Expiry: number): any
					error("the map is down", 0)
				end,
				UpdateAsync = function(_: any, _Key: string, _Transform: (any) -> any, _Expiry: number): any
					error("the map is down", 0)
				end,
				RemoveAsync = function(_: any, _Key: string)
					error("the map is down", 0)
				end,
			}
		end,
	}
end

local function Built(T: Case, Name: string, Hook: Engine.Hook?, Migrations: { any }?): any
	return Ledger.New({
		Name = Name,
		Keys = "String",
		Default = Reducers.MONEY,
		Reducer = Reducers.Banker,
		Balance = "Gold",
		Migrations = Migrations,
		Hook = Hook or T.Hook,
	})
end

Cases.Case("a peek with a MaxAge reads the record once and answers the copy after, on this server and on another", function(T: Case)
	local A, B = T:Bank("nodeA"), T:Bank("nodeB")
	T:Ok("the edit", Fund(A, KEY, 5))

	local First, Second, Third
	local ColdUnits, WarmUnits, OtherUnits = 0, 0, 0
	local Cold = Reads(A, function()
		ColdUnits = Units(T, function()
			First = Gold(A, KEY, AGE)
		end)
	end)
	local Warm = Reads(A, function()
		WarmUnits = Units(T, function()
			Second = Gold(A, KEY, AGE)
		end)
	end)
	local Other = Reads(B, function()
		OtherUnits = Units(T, function()
			Third = Gold(B, KEY, AGE)
		end)
	end)

	T:Is("the gold read cold", First, 5)
	T:Is("datastore reads on the cold peek", Cold, 1)
	T:Is("units on the cold peek, a read, a claim and a refill", ColdUnits, MemoryStore.UNIT + MemoryStore.UPDATE_UNITS * 2)
	T:Is("the gold read warm", Second, 5)
	T:Is("datastore reads on the warm peek", Warm, 0)
	T:Is("units on the warm peek", WarmUnits, 0)
	T:Is("the gold another server reads", Third, 5)
	T:Is("datastore reads on the other server", Other, 0)
	T:Is("units on the other server, one read of the item", OtherUnits, MemoryStore.UNIT)
end)

Cases.Case("the copy carries the game's fields and none of Ledger's own", function(T: Case)
	local A = T:Bank("nodeA")
	A:Seed(KEY, { Gold = 5, Touches = 0, _Received = { ["o:gift"] = T:Now() } })

	local Plain = A.Store:Peek(KEY):Wait()
	local Copied = A.Store:Peek(KEY, AGE):Wait()
	local Stored = Item(T, A, KEY)

	T:Ok("a plain peek carries the applied names", type(Plain._Received) == "table")
	T:Is("a peek with a MaxAge carries the gold", Copied.Gold, 5)
	T:Is("and the touches", Copied.Touches, 0)
	T:Is("and no applied names", Copied._Received, nil)
	T:Is("the item holds no applied names either", Stored.State._Received, nil)
	T:Ok("the item carries the stamp the datastore put on the record", type(Stored.Stamp) == "number")
end)

Cases.Case("a stale copy is refilled by one server while the rest answer it and read nothing", function(T: Case)
	local A, B, C = T:Bank("nodeA"), T:Bank("nodeB"), T:Bank("nodeC")
	T:Ok("the edit", Fund(A, KEY, 5))
	T:Is("the first copy", Gold(A, KEY, AGE), 5)
	T:Ok("the other server's edit", Fund(B, KEY, 7))
	T:Advance(STALE)

	local Meanwhile, MeanwhileReads, MeanwhileUnits
	local Spec = A:Fault(Fault.Reads():OnKey(KEY):Only(1):Meddle(function()
		MeanwhileReads = Reads(C, function()
			MeanwhileUnits = Units(T, function()
				Meanwhile = Gold(C, KEY, AGE)
			end)
		end)
	end))
	local Refilled
	local RefillReads = Reads(A, function()
		Refilled = Gold(A, KEY, AGE)
	end)
	T:Advance(AGE + 1)
	local After = Gold(C, KEY, AGE)

	T:Is("the meddle fired on the refill's read of the record", Spec.Fired, 1)
	T:Is("the gold a bystander answered while the refill ran, the old copy", Meanwhile, 5)
	T:Is("datastore reads the bystander spent", MeanwhileReads, 0)
	T:Is("units the bystander spent, one read and no claim", MeanwhileUnits, MemoryStore.UNIT)
	T:Is("the gold the refiller answered", Refilled, 12)
	T:Is("datastore reads the refiller spent", RefillReads, 1)
	T:Is("the bystander's gold once its copy aged out", After, 12)
end)

Cases.Case("two servers judge one item stale a little apart, so one of them refills it alone", function(T: Case)
	local A, B = T:Bank("nodeA"), T:Bank("nodeB")
	T:Ok("the edit", Fund(A, KEY, 5))
	T:Is("the first copy", Gold(A, KEY, AGE), 5)
	T:Is("the other server's copy", Gold(B, KEY, AGE), 5)
	A.Store:Copy(KEY).Slack = SLACK
	B.Store:Copy(KEY).Slack = 0
	T:Advance(CACHE + 1)

	local Early, EarlyUnits
	local EarlyReads = Reads(A, function()
		EarlyUnits = Units(T, function()
			Early = Gold(A, KEY, AGE)
		end)
	end)
	local Late
	local LateReads = Reads(B, function()
		Late = Gold(B, KEY, AGE)
	end)
	T:Advance(AGE + 1)
	local After
	local AfterReads = Reads(A, function()
		After = Gold(A, KEY, AGE)
	end)

	T:Is("the gold the server with slack answered a minute in, the item as it stood", Early, 5)
	T:Is("datastore reads it spent", EarlyReads, 0)
	T:Is("units it spent, one read of the item and no claim", EarlyUnits, MemoryStore.UNIT)
	T:Is("the gold the server with no slack answered", Late, 5)
	T:Is("datastore reads it spent, the one refill between them", LateReads, 1)
	T:Is("the first server once its copy aged, the refilled item", After, 5)
	T:Is("datastore reads it spent, none, since the other server refilled", AfterReads, 0)
end)

Cases.Case("a write on this server shows in its own copy at once and on another server after a refill", function(T: Case)
	local A, B = T:Bank("nodeA"), T:Bank("nodeB")
	T:Ok("the edit", Fund(A, KEY, 5))
	T:Is("the first copy", Gold(A, KEY, AGE), 5)
	T:Is("the other server's first copy", Gold(B, KEY, AGE), 5)

	T:Ok("the second edit", Fund(A, KEY, 7))
	local Own, OwnUnits
	local OwnReads = Reads(A, function()
		OwnUnits = Units(T, function()
			Own = Gold(A, KEY, AGE)
		end)
	end)
	T:Advance(AGE + 1)
	local Theirs = Gold(B, KEY, AGE)
	T:Advance(STALE)
	local Later = Gold(B, KEY, AGE)

	T:Is("the writing server's copy, at once", Own, 12)
	T:Is("datastore reads to learn that", OwnReads, 0)
	T:Is("units to learn that", OwnUnits, 0)
	T:Is("the other server inside the window, the item as it was", Theirs, 5)
	T:Is("the other server once the item aged and it refilled", Later, 12)
end)

Cases.Case("a peek with a MaxAge of zero refills through the claim, and one right after it answers the refill", function(T: Case)
	local A, B, C = T:Bank("nodeA"), T:Bank("nodeB"), T:Bank("nodeC")
	T:Ok("the edit", Fund(A, KEY, 5))
	T:Is("the first copy", Gold(A, KEY, AGE), 5)
	T:Advance(CLAIM + 1)
	T:Ok("the other server's edit", Fund(B, KEY, 7))

	local Forced
	local ForcedReads = Reads(A, function()
		Forced = Gold(A, KEY, 0)
	end)
	local Nudged
	local NudgedReads = Reads(C, function()
		Nudged = Gold(C, KEY, 0)
	end)
	T:Advance(CLAIM + 1)
	local Again
	local AgainReads = Reads(C, function()
		Again = Gold(C, KEY, 0)
	end)

	T:Is("the gold a forced peek answers", Forced, 12)
	T:Is("datastore reads the forced peek spent", ForcedReads, 1)
	T:Is("the gold a second forced peek answers right after", Nudged, 12)
	T:Is("datastore reads it spent, none, since the item was refilled inside the claim window", NudgedReads, 0)
	T:Is("the gold once the claim window passed", Again, 12)
	T:Is("datastore reads that one spent", AgainReads, 1)
end)

Cases.Case("a follower ticks, backs off while nothing moves, and pushes once when the key does", function(T: Case)
	local A, B = T:Bank("nodeA"), T:Bank("nodeB")
	T:Ok("the edit", Fund(A, KEY, 5))

	local Pushed: { number } = {}
	A.Store:Follow(KEY):Subscribe(function(State: any)
		table.insert(Pushed, State.Gold)
	end)
	T:Ok(
		"the first tick pushed",
		T:Until(function(): boolean
			return #Pushed > 0
		end)
	)

	local Ticks = FOLLOW_CAP * 2 // FOLLOW
	local Refills = Reads(A, function()
		for _ = 1, Ticks do
			T:Wait(FOLLOW)
		end
	end)
	local Still = #Pushed

	T:Ok("the other server's edit", Fund(B, KEY, 7))
	T:Ok(
		"the follower pushed the change",
		T:Until(function(): boolean
			return #Pushed > 1
		end)
	)

	T:Is("the first push", Pushed[1], 5)
	T:Is("pushes over a quiet spell", Still, 1)
	T:Ok(`refills over a quiet spell of {Ticks} ticks, {Refills}, no more than a tick doubling to its cap makes`, Refills <= 3)
	T:Ok("and more than none, so the follower kept reading", Refills > 0)
	T:Is("the second push", Pushed[2], 12)
	T:Is("pushes in all", #Pushed, 2)
end)

Cases.Case("a follower's ticker stops when the last listener leaves and starts again on the next", function(T: Case)
	local A = T:Bank("nodeA")
	T:Ok("the edit", Fund(A, KEY, 5))

	local Pushed = 0
	local Stream = A.Store:Follow(KEY)
	local Connection = Stream:Subscribe(function()
		Pushed += 1
	end)
	T:Ok(
		"the first tick pushed",
		T:Until(function(): boolean
			return Pushed > 0
		end)
	)
	local Copy = A.Store:Copy(KEY)
	local Ticking = Copy.Ticker ~= nil

	Connection:Disconnect()
	local Stopped = Copy.Ticker == nil
	local Idle = Units(T, function()
		T:Advance(FOLLOW_CAP)
		T:Wait(1)
	end)

	Stream:Subscribe(function()
		Pushed += 1
	end)
	local Resumed = Copy.Ticker ~= nil

	T:Ok("the ticker ran while a listener was on", Ticking)
	T:Ok("the ticker stopped when the last listener left", Stopped)
	T:Is("units spent while nobody listened", Idle, 0)
	T:Ok("the ticker started again on the next listener", Resumed)
	T:Ok("the same stream is handed back for one key", A.Store:Follow(KEY) == Stream)
end)

Cases.Case("destroying a store stops its followers", function(T: Case)
	local Store = Built(T, "CaseFollowsGone")
	Store:Edit(KEY, "Fund", { Amount = 5 }):Wait()

	local Pushed = 0
	Store:Follow(KEY):Subscribe(function()
		Pushed += 1
	end)
	T:Ok(
		"the first tick pushed",
		T:Until(function(): boolean
			return Pushed > 0
		end)
	)
	local Copy = Store:Copy(KEY)

	Store:Destroy()
	local Idle = Units(T, function()
		T:Advance(FOLLOW_CAP)
		T:Wait(1)
	end)

	T:Is("the ticker once the store was destroyed", Copy.Ticker, nil)
	T:Is("copies the store keeps", Store.Copies.Count, 0)
	T:Is("copies it follows", next(Store.Followed), nil)
	T:Is("units spent after", Idle, 0)
end)

Cases.Case("a map that stops answering holds a follower to its copy, and a cold server reads the record once a window", function(T: Case)
	local Store = Built(T, "CaseFollowsDown", Broken(T))
	Store:Edit(KEY, "Fund", { Amount = 5 }):Wait()

	local First, Second, Third
	local Cold = Reads({ Store = Store } :: any, function()
		First = (Store:Peek(KEY, AGE):Wait() :: any).Gold
	end)
	T:Advance(AGE + 1)
	local Warm = Reads({ Store = Store } :: any, function()
		Second = (Store:Peek(KEY, AGE):Wait() :: any).Gold
	end)
	T:Advance(KEEP + 1)
	local Aged = Reads({ Store = Store } :: any, function()
		Third = (Store:Peek(KEY, AGE):Wait() :: any).Gold
	end)

	T:Is("the first peek", First, 5)
	T:Is("datastore reads on the first, the record", Cold, 1)
	T:Is("the second peek", Second, 5)
	T:Is("datastore reads on the second, which the copy answers", Warm, 0)
	T:Is("the third peek", Third, 5)
	T:Is("datastore reads once the copy is too old to answer with", Aged, 1)
	T:Warns("it said the map did not answer", "did not answer")
end)

Cases.Case("a cold server with no copy and no read budget answers Unresolved while the map is down", function(T: Case)
	local Store = Built(T, "CaseFollowsStarved", Broken(T))
	Store.Wrapper.Budgets = function(_Kind: Enum.DataStoreRequestType): number
		return 0
	end

	local State, Why = Store:Peek(KEY, AGE):Wait()

	T:Is("the state", State, nil)
	T:Is("the reason", Why, Reasons.Unresolved)
end)

Cases.Case("a cold fleet reads the record once, and a server under the claim answers nothing rather than reading", function(T: Case)
	local A, B = T:Bank("nodeA"), T:Bank("nodeB")
	T:Ok("the edit", Fund(A, KEY, 5))

	local Meanwhile, Why, MeanwhileReads
	local Spec = A:Fault(Fault.Reads():OnKey(KEY):Only(1):Meddle(function()
		MeanwhileReads = Reads(B, function()
			Meanwhile, Why = Gold(B, KEY, AGE)
		end)
	end))
	local First = Gold(A, KEY, AGE)
	local After = Gold(B, KEY, AGE)

	T:Is("the meddle fired on the first server's read", Spec.Fired, 1)
	T:Is("the gold the second server answered under the claim", Meanwhile, nil)
	T:Is("its reason", Why, Reasons.Unresolved)
	T:Is("datastore reads it spent", MeanwhileReads, 0)
	T:Is("the first server's gold", First, 5)
	T:Is("the second server's gold once the refill landed", After, 5)
end)

Cases.Case("a refill keeps a newer copy that landed while it was reading", function(T: Case)
	local A = T:Bank("nodeA")
	T:Ok("the edit", Fund(A, KEY, 5))
	T:Is("the first copy", Gold(A, KEY, AGE), 5)
	T:Advance(STALE)

	local Spec = A:Fault(Fault.Reads():OnKey(KEY):Only(1):Meddle(function()
		Plant(T, A, KEY, { State = { Gold = 99, Touches = 0 }, Stamp = (A.Store:Copy(KEY).Stamp or 0) + 1, At = T:Now() + 1 })
	end))
	local Own = Gold(A, KEY, AGE)
	T:Advance(AGE + 1)
	local Next = Gold(A, KEY, AGE)

	T:Is("the meddle fired on the refill's read", Spec.Fired, 1)
	T:Is("the refiller's own answer, from the record it read", Own, 5)
	T:Is("the gold once the refill met the newer copy", Next, 99)
end)

Cases.Case("an older build's copy is refilled through this build's migrations, and a newer build's copy answers Behind", function(T: Case)
	local Old = T:Bank("nodeA")
	Old:Seed(KEY, { Gold = 5, Touches = 0 })
	local New = Built(T, "CaseFollowsNew", T.Hook, {
		function(State: any): any
			local Next = table.clone(State)
			Next.Level = 1
			return Next
		end,
	})
	New.Wrapper = Old.Store.Wrapper
	New.Books, New.Shaped = nil, nil

	T:Is("the old build's copy", Gold(Old, KEY, AGE), 5)
	local Stale = Item(T, Old, KEY)
	local Migrated: any = nil
	local Refill = Reads(Old, function()
		Migrated = New:Peek(KEY, AGE):Wait()
	end)
	local Fresh = Item(T, Old, KEY)

	T:Advance(AGE + 1)
	local Held, Why = Old.Store:Peek(KEY, AGE):Wait()
	T:Advance(AGE + 1)
	local Again = Old.Store:Peek(KEY, AGE):Wait()

	T:Is("the item the old build wrote, at its version", Stale.Version, 0)
	T:Is("and its floor", Stale.Floor, 0)
	T:Is("the new build read the record rather than trusting it", Refill, 1)
	T:Is("the new build's copy, migrated", Migrated.Level, 1)
	T:Is("the item the new build wrote, at its version", Fresh.Version, 1)
	T:Is("the floor it carries", Fresh.Floor, 1)
	T:Is("the old build's copy against it", Held, nil)
	T:Is("its reason", Why, Reasons.Behind)
	T:Is("and again", Again, nil)
	T:Warns("it said so once", "finish the deploy", 1)
end)

Cases.Case("a state too big for an item is read from the record by every server and said once a window", function(T: Case)
	local A, B = T:Bank("nodeA"), T:Bank("nodeB")
	A:Seed(KEY, { Gold = 5, Touches = 0, Blob = string.rep("x", MemoryStore.MAX_ITEM) })

	local First
	local Cold = Reads(A, function()
		First = Gold(A, KEY, AGE)
	end)
	local Stored = Item(T, A, KEY)
	local Second
	local Other = Reads(B, function()
		Second = Gold(B, KEY, AGE)
	end)
	T:Advance(AGE + 1)
	local Third
	local Again = Reads(B, function()
		Third = Gold(B, KEY, AGE)
	end)

	T:Is("the first server's gold", First, 5)
	T:Is("datastore reads it spent", Cold, 1)
	T:Is("the item, taken off so nobody waits on it", Stored, nil)
	T:Is("the second server's gold, at once", Second, 5)
	T:Is("datastore reads it spent, its own", Other, 1)
	T:Is("the second server's gold once its copy aged", Third, 5)
	T:Is("datastore reads that spent, its own again", Again, 1)
	T:Warns("each server said the key is too big to copy, once a window, and the second server read in two", "keep a followed key small", 3)
end)

Cases.Case("a state holding a buffer is read from the record rather than copied", function(T: Case)
	local Store = T:Store({ Default = Reducers.STASH, Reducer = Reducers.Stasher, Balance = "Gold" })
	Store:Seed(KEY, { Gold = 5, Touches = 0, Blobs = { slot = buffer.create(4) } })

	local First
	local Cold = Reads(Store, function()
		First = Gold(Store, KEY, AGE)
	end)
	local Stored = Item(T, Store, KEY)

	T:Is("the gold", First, 5)
	T:Is("datastore reads", Cold, 1)
	T:Is("the item, taken off so nobody waits on it", Stored, nil)
	T:Warns("it said the key holds a buffer", "holds a buffer", 1)
end)

Cases.Case("erasing a key takes its copy item off", function(T: Case)
	local A = T:Bank("nodeA")
	T:Ok("the edit", Fund(A, KEY, 5))
	T:Is("the copy", Gold(A, KEY, AGE), 5)
	T:Ok("the item before", Item(T, A, KEY) ~= nil)

	T:Ok("the erase", (A.Store:Erase(KEY):Wait()))
	local Gone = Item(T, A, KEY)
	local Own = Gold(A, KEY, AGE)

	T:Is("the item after", Gone, nil)
	T:Is("this server's own copy after, the default and not what it held", Own, 0)
	T:Warns("it said what the erase destroyed", "destroyed 5 Gold")
end)

Cases.Case("a follow and a peek with a MaxAge are for string keyed stores, and a MaxAge has to be a number of seconds", function(T: Case)
	local Players = T:Players()
	local A = T:Bank("nodeA")

	T:Throws("a follow on a player store", function()
		Players.Store:Follow(1)
	end)
	T:Throws("a peek with a MaxAge on a player store", function()
		Players.Store:Peek(1, AGE)
	end)
	T:Throws("a MaxAge below zero", function()
		A.Store:Peek(KEY, -1)
	end)
	T:Holds("a plain peek on a player store", function()
		Players.Store:Peek(1):Wait()
	end)
end)

Cases.Case("a store with no MemoryStore reads the record on every tick and says so at build", function(T: Case)
	local Hook: Engine.Hook = { Open = T.Hook.Open, Budget = T.Hook.Budget }
	local Store = Built(T, "CaseFollowsBare", Hook)
	Store:Edit(KEY, "Fund", { Amount = 5 }):Wait()

	local First, Second
	local Cold = Reads({ Store = Store } :: any, function()
		First = (Store:Peek(KEY, AGE):Wait() :: any).Gold
	end)
	local Warm = Reads({ Store = Store } :: any, function()
		Second = (Store:Peek(KEY, AGE):Wait() :: any).Gold
	end)
	T:Advance(AGE + 1)
	local Aged = Reads({ Store = Store } :: any, function()
		Store:Peek(KEY, AGE):Wait()
	end)

	T:Is("the first peek", First, 5)
	T:Is("the second peek", Second, 5)
	T:Is("datastore reads on the first", Cold, 1)
	T:Is("datastore reads on the second, which the copy answers", Warm, 0)
	T:Is("datastore reads once the copy aged", Aged, 1)
	T:Warns("it said the store has no MemoryStore", "no MemoryStore", 1)
end)

Cases.Case("a refill that read the record before this server's own write keeps the newer copy", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("behind", { Gold = 1 })
	T:Is("the first peek fills the copy", (Bank.Store:Peek("behind", 60):Wait()).Gold, 1)
	T:Advance(20)

	local Written = Bank.Hook.Fail(Fault.Updates():OnStore(Follows.MAP):Only(2):Meddle(function()
		Bank.Store:Edit("behind", "Fund", { Amount = 10 }):Wait()
	end))
	Bank.Store:Peek("behind", 0):Wait()
	local Copy = Bank.Store:Peek("behind", 60):Wait()

	T:Is("the edit ran inside the refill", Written.Fired, 1)
	T:Is("this server's copy, which shows its own write", Copy.Gold, 11)
	T:Is("the record", Bank:Amount("behind"), 11)
end)

Cases.Case("what a copy hands back is frozen, from this server, from another server's item and from a follow", function(T: Case)
	local Here = T:Bank("nodeA")
	local There = T:Bank("nodeB")
	Here:Seed("frozen", { Gold = 5 })
	Here:Seed("pushed", { Gold = 5 })

	local function Poked(Value: any): boolean
		return (pcall(function()
			Value.Gold = -999
		end))
	end

	local Own = Here.Store:Peek("frozen", 60):Wait()
	local Theirs = There.Store:Peek("frozen", 60):Wait()
	local Pushed: any = nil
	Here.Store:Follow("pushed"):Subscribe(function(State: any)
		Pushed = Pushed or State
	end)
	T:Advance(FOLLOW + 1)
	T:Until(function(): boolean
		return Pushed ~= nil
	end)

	T:Ok("the follow pushed a state", type(Pushed) == "table")
	T:No("a write into this server's copy", Poked(Own))
	T:No("a write into a copy from another server's item", Poked(Theirs))
	T:No("a write into what a follow pushed", Poked(Pushed))
	T:Is("what the next caller sees", (Here.Store:Peek("frozen", 60):Wait()).Gold, 5)
end)

Cases.Case("copies of keys nobody follows are bounded", function(T: Case)
	local Bank = T:Bank()
	Bank.Store:Follow("kept"):Subscribe(function() end)
	local Followed = Bank.Store:Copy("kept")
	for Index = 1, 900 do
		Bank.Store:Peek(`many{Index}`, 30):Wait()
	end

	T:Is("copies held after peeking 900 keys", Bank.Store.Copies.Count, 256)
	T:Is("the followed copy is still the one held", Bank.Store:Copy("kept"), Followed)
	T:Is("the latest peeked copy is held", Bank.Store.Copies:Get("many900") ~= nil, true)
end)

return Cases
