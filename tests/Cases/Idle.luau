--!strict
--!optimize 2

--[=[

	Idle: One rule per promise the flag on a written key makes to an idle session.

	A write on any server sets the datastore's version of the key in the MemoryStore once the write
	went through, and a slower flag from an older write cannot put it back. An idle session reads
	the key on its next tick only when that version is not the one it folded, its own flush leaves
	it nothing to read, the every fourth tick read stays whatever the flag says, and a flag that
	cannot be reached or was never set falls back to that read.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau idle
--]=]

local Suite = require("../Suite")

local Mark = require("../../src/Encode/Mark")
local Log = require("../../src/Record/Log")
local Sessions = require("../../src/Core/Constants/Sessions")
local Wrapper = require("../../src/Util/MemoryStoreWrapper")

local Fault = Suite.Fault
local Reducers = Suite.Reducers

type Case = Suite.Case
type Fixture = Suite.Fixture

local Cases = Suite.File("Idle", { "cache" })

local MAP = Sessions.FLAG_MAP
local EVERY = Sessions.IDLE_EVERY
local MISSES = Wrapper.Misses

local function Bank(T: Case, Node: string): Fixture
	return T:Store({ Keys = "Player", Default = Reducers.MONEY, Reducer = Reducers.Banker, Balance = "Gold", Node = Node })
end

local function Pair(T: Case): (Fixture, Fixture)
	return Bank(T, "nodeA"), Bank(T, "nodeB")
end

local function Loaded(T: Case, Held: Fixture, UserId: number): any
	local Fake = T:Player(UserId)
	Held.Store:Load(Fake)
	T:Wait()
	return Held.Store:Expect(Fake)
end

local function Tick(T: Case, Held: Fixture, UserId: number): number
	local Entry = Held.Store.Loaded[UserId]
	local Was = Entry.Ticks
	local Before = Held.Store.Wrapper.Spent
	T:Until(function(): boolean
		return Entry.Ticks > Was
	end)
	T:Wait(1)
	return Held.Store.Wrapper.Spent - Before
end

local function Slot(Held: Fixture, UserId: number): string
	return Mark.Cached({ Held.Data, tostring(UserId) })
end

local function Flag(T: Case, Held: Fixture, UserId: number): string?
	return Log.Flagged(T.Service:GetHashMap(MAP):GetAsync(Slot(Held, UserId)))
end

local function Version(Held: Fixture, UserId: number): string?
	local _, Info = Held.Direct:Current(tostring(UserId))
	return if Info ~= nil then Info.Version else nil
end

local function Checks(Held: Fixture): number
	return Held.Store.Flags.Spent
end

Cases.Case("a write on another server flags the key, and an idle session reads it on its next tick", function(T: Case)
	local A, B = Pair(T)
	B:Seed("71", { Gold = 100, Touches = 0 })
	local Live = Loaded(T, B, 71)

	local Quiet = Tick(T, B, 71)
	local Before = Live:Get().Gold
	T:Ok("the edit on the other server", (A.Store:Edit(71, "Fund", { Amount = 5 }):Wait()))
	T:Wait()
	local Seen = Tick(T, B, 71)

	T:Is("reads on a tick with nothing flagged", Quiet, 0)
	T:Is("gold the session held before that write", Before, 100)
	T:Is("reads on the tick after the write", Seen, 1)
	T:Is("gold the session reads after it", Live:Get().Gold, 105)
	T:Is("flag checks, one per tick", Checks(B), 2)
	T:Is("the flag, the version the session now holds", Flag(T, B, 71), Live.Revision)
end)

Cases.Case("a flag that has not moved skips the read, and the fallback tick reads whatever it says", function(T: Case)
	local A, B = Pair(T)
	B:Seed("72", { Gold = 100, Touches = 0 })
	local Live = Loaded(T, B, 72)
	A.Store:Edit(72, "Fund", { Amount = 5 }):Wait()
	T:Wait()

	local Reads: { number } = {}
	for Index = 1, EVERY do
		Reads[Index] = Tick(T, B, 72)
	end

	T:Is("reads on the first tick, the flag moved", Reads[1], 1)
	T:Is("reads on the second, the flag is the version it folded", Reads[2], 0)
	T:Is("reads on the third", Reads[3], 0)
	T:Is("reads on the fourth, the fallback", Reads[EVERY], 1)
	T:Is("flag checks, none on the fallback tick", Checks(B), EVERY - 1)
	T:Is("gold the session reads", Live:Get().Gold, 105)
end)

Cases.Case("a flag check that cannot reach the map reads on the fallback tick as today", function(T: Case)
	local A, B = Pair(T)
	B:Seed("73", { Gold = 100, Touches = 0 })
	local Live = Loaded(T, B, 73)
	local Down = B.Hook.Fail(Fault.Reads():OnStore(MAP))
	A.Store:Edit(73, "Fund", { Amount = 5 }):Wait()
	T:Wait()

	local Reads: { number } = {}
	for Index = 1, EVERY do
		Reads[Index] = Tick(T, B, 73)
	end

	T:Is("reads on the ticks the map was down for", Reads[1] + Reads[2] + Reads[3], 0)
	T:Is("reads on the fallback tick", Reads[EVERY], 1)
	T:Is("times the map was asked", Down.Fired, EVERY - 1)
	T:Is("gold the session reads once the fallback read", Live:Get().Gold, 105)
	T:Warns("it said the map did not answer", "did not answer")
end)

Cases.Case("after a run of misses the flag map is left alone for a window, and the first answer starts it again", function(T: Case)
	local A, B = Pair(T)
	B:Seed("74", { Gold = 100, Touches = 0 })
	local Live = Loaded(T, B, 74)
	local Down = B.Hook.Fail(Fault.Reads():OnStore(MAP))

	for _ = 1, MISSES do
		Tick(T, B, 74)
	end
	local Asked = Down.Fired
	for _ = 1, EVERY - 1 do
		Tick(T, B, 74)
	end
	local Resting = Down.Fired

	B:Healed()
	A.Store:Edit(74, "Fund", { Amount = 5 }):Wait()
	T:Wait()
	local Woken = Tick(T, B, 74)

	T:Is("misses before it stopped asking", Asked, MISSES)
	T:Is("asks while the map was left alone", Resting - Asked, 0)
	T:Is("reads on the first tick after that", Woken, 1)
	T:Is("gold the session reads", Live:Get().Gold, 105)
	T:Is("checks once the map answered", Checks(B), MISSES + 1)
end)

Cases.Case("a flag the writer could not set is caught by the fallback read", function(T: Case)
	local A, B = Pair(T)
	B:Seed("75", { Gold = 100, Touches = 0 })
	local Live = Loaded(T, B, 75)
	local Lost = A.Hook.Fail(Fault.Updates():OnStore(MAP))
	T:Ok("the edit", (A.Store:Edit(75, "Fund", { Amount = 5 }):Wait()))
	T:Wait()

	local Reads: { number } = {}
	for Index = 1, EVERY do
		Reads[Index] = Tick(T, B, 75)
	end

	T:Is("the flag set that was lost", Lost.Fired, 1)
	T:Is("the flag", Flag(T, B, 75), nil)
	T:Is("reads before the fallback tick", Reads[1] + Reads[2] + Reads[3], 0)
	T:Is("reads on the fallback tick", Reads[EVERY], 1)
	T:Is("gold the session reads after it", Live:Get().Gold, 105)
	T:Warns("the writer said the map did not answer", "did not answer")
end)

Cases.Case("the flag is set after the write went through, and holds the version the record reads back with", function(T: Case)
	local A = Bank(T, "nodeA")
	A:Seed("76", { Gold = 100, Touches = 0 })

	local Seen: { any } = {}
	local Fired = 0
	A:Fault(Fault.Updates():OnKey("76"):Meddle(function()
		Fired += 1
		Seen[Fired] = Flag(T, A, 76)
	end))
	A.Store:Edit(76, "Fund", { Amount = 5 }):Wait()
	T:Wait()
	local First, FirstVersion = Flag(T, A, 76), Version(A, 76)
	A.Store:Edit(76, "Fund", { Amount = 5 }):Wait()
	T:Wait()
	local Second, SecondVersion = Flag(T, A, 76), Version(A, 76)

	T:Is("writes the meddle saw go in", Fired, 2)
	T:Is("the flag as the first write went in", Seen[1], nil)
	T:Is("the flag once the first write had gone through", First, FirstVersion)
	T:Is("the flag as the second write went in, still the first", Seen[2], FirstVersion)
	T:Is("the flag once the second write had gone through", Second, SecondVersion)
	T:Ok("the two versions differ", FirstVersion ~= SecondVersion)
end)

Cases.Case("a slower flag from an older write cannot put the flag back, so the newer version stands", function(T: Case)
	local A, B = Pair(T)
	local C = Bank(T, "nodeC")
	B:Seed("83", { Gold = 100, Touches = 0 })
	local Older = Loaded(T, B, 83)

	local Slow = A.Hook.Fail(Fault.Updates():OnStore(MAP):Only(1):Stall(5))
	T:Ok("the first write, whose flag is slow", (A.Store:Edit(83, "Fund", { Amount = 5 }):Wait()))
	T:Ok("the second write, whose flag lands first", (C.Store:Edit(83, "Fund", { Amount = 5 }):Wait()))
	T:Wait()
	local Before = B.Store.Wrapper.Spent
	local Newer = Loaded(T, C, 83)
	local Landed = Flag(T, B, 83)
	T:Wait(6)
	local Settled = Flag(T, B, 83)

	local Skipped = Tick(T, C, 83)
	Tick(T, B, 83)
	local Read = B.Store.Wrapper.Spent - Before

	T:Is("the slow flag fired", Slow.Fired, 1)
	T:Is("the flag once the second write's flag landed", Landed, Version(B, 83))
	T:Is("the flag once the slow one landed too, still the second", Settled, Version(B, 83))
	T:Is("reads by the session that folded the second write", Skipped, 0)
	T:Is("gold it holds", Newer:Get().Gold, 110)
	T:Is("reads by the session that folded the seed, one and not one per tick", Read, 1)
	T:Is("gold it reads", Older:Get().Gold, 110)
end)

Cases.Case("a session's own flush flags the key, and its next idle tick does not read", function(T: Case)
	local B = Bank(T, "nodeB")
	B:Seed("77", { Gold = 100, Touches = 0 })
	local Live = Loaded(T, B, 77)
	local Sets = B.Hook.Fail(Fault.Updates():OnStore(MAP):Only(999))
	T:Ok("the apply", (Live:Apply("Fund", { Amount = 5 })))

	local Wrote = Tick(T, B, 77)
	local Idle = Tick(T, B, 77)
	local Again = Tick(T, B, 77)

	T:Is("writes on the tick that flushed", Wrote, 1)
	T:Is("flag sets that flush made", Sets.Count, 1)
	T:Is("the flag, the version the flush wrote", Flag(T, B, 77), Version(B, 77))
	T:Is("and the version the session holds", Live.Revision, Version(B, 77))
	T:Is("reads on the idle tick after it", Idle, 0)
	T:Is("reads on the one after that", Again, 0)
	T:Is("map calls in all, one set and two checks", Checks(B), 3)
	T:Is("gold on the key", B:Stored("77").Gold, 105)
end)

Cases.Case("a transaction on another server flags every key it touched, and each idle session reads once", function(T: Case)
	local A, B = Pair(T)
	B:Seed("78", { Gold = 100, Touches = 0 })
	B:Seed("79", { Gold = 0, Touches = 0 })
	local Left = Loaded(T, B, 78)
	local Right = Loaded(T, B, 79)

	local Ok = A.Store
		:Tx("idle1", {
			{ UserId = 78, Kind = "Give", Fields = { Amount = -30 } },
			{ UserId = 79, Kind = "Give", Fields = { Amount = 30 } },
		})
		:Wait()
	T:Wait()

	local Entries = { B.Store.Loaded[78], B.Store.Loaded[79] }
	local Was = { Entries[1].Ticks, Entries[2].Ticks }
	local Before = B.Store.Wrapper.Spent
	T:Until(function(): boolean
		return Entries[1].Ticks > Was[1] and Entries[2].Ticks > Was[2]
	end)
	T:Wait(1)

	T:Ok("the transaction", Ok)
	T:Is("reads the two sessions made between them", B.Store.Wrapper.Spent - Before, 2)
	T:Is("gold the sender's session reads", Left:Get().Gold, 70)
	T:Is("gold the receiver's session reads", Right:Get().Gold, 30)
end)

Cases.Case("a transfer another server finished for a stopped one is seen by the receiver's idle session", function(T: Case)
	local A, B = Pair(T)
	B:Write("80", {
		Snapshot = { Gold = 60, Touches = 0, _Held = { rest1 = { To = "81", Amount = 40, At = T:Now() - 60 } } },
		Ops = {},
		Seen = {},
	})
	B:Seed("81", { Gold = 0, Touches = 0 })
	local Live = Loaded(T, B, 81)
	local Quiet = Tick(T, B, 81)

	local Ok = A.Store:Resettle(80):Wait()
	T:Wait()
	local Seen = Tick(T, B, 81)

	T:Is("reads before the recovery", Quiet, 0)
	T:Ok("the recovery on the other server", Ok)
	T:Is("money the sender still holds aside", A:Aside("80"), 0)
	T:Is("reads on the tick after it", Seen, 1)
	T:Is("gold the receiver's session reads", Live:Get().Gold, 40)
end)

return Cases
