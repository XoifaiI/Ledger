--!strict
--!optimize 2

--[=[

	Cached: One rule per promise the fake MemoryStore and its wrapper make.

	Key, name and item caps, and expiry on the clock. A transform that sees the item and runs again
	when a write lands under it. The unit costs, the two quotas, and a wrapper that calls once and
	answers a miss. A fake looser than the real service lets a lease pass in a case and fail live.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau
--]=]

local Suite = require("../Suite")

local Engine = require("../../src/Util/Engine")
local Datastore = require("../../src/Core/Constants/Datastore")
local MemoryStore = require("../../src/Core/Constants/MemoryStore")
local Memory = require("../../src/Hooks/Memory")
local Wrapper = require("../../src/Util/MemoryStoreWrapper")
local Mock = require("../../src/Mock")

type Case = Suite.Case

local Cases = Suite.File("Cached", { "cache" })

local MINUTE = 60

local function Fresh(T: Case, Options: any?): Mock.Service
	return Mock.New(Options or { Throttled = false }, T.Turn)
end

local function Refuses(Body: () -> ()): boolean
	return not pcall(Body)
end

local function Down(): any
	error("the map is down", 0)
end

local BROKEN: Engine.Map = {
	GetAsync = function(_: any, _Key: string): any
		return Down()
	end,
	SetAsync = function(_: any, _Key: string, _Value: any, _Expiry: number): any
		return Down()
	end,
	UpdateAsync = function(_: any, _Key: string, _Transform: (any) -> any, _Expiry: number): any
		return Down()
	end,
	RemoveAsync = function(_: any, _Key: string)
		Down()
	end,
}

local function Broken(T: Case): Engine.Hook
	return {
		Open = T.Hook.Open,
		Budget = T.Hook.Budget,
		Cache = function(_Name: string): Engine.Map
			return BROKEN
		end,
	}
end

local function Refused(T: Case, Label: string, Body: () -> ())
	T:Ok(Label, Refuses(Body))
end

Cases.Case("an item reads back as a copy and a missing key reads as nothing", function(T: Case)
	local Map = Fresh(T):GetHashMap("Plain")

	T:Is("a key nothing wrote", Map:GetAsync("none"), nil)

	Map:SetAsync("k", { N = 1 }, MINUTE)
	local Got = Map:GetAsync("k")
	Got.N = 99

	T:Is("what the read handed back", Got.N, 99)
	T:Is("what is on the key after the copy was changed", (Map:GetAsync("k") :: any).N, 1)
end)

Cases.Case("an item runs out on the clock and one written to live for no time is gone at once", function(T: Case)
	local Map = Fresh(T):GetHashMap("Aging")

	Map:SetAsync("k", 1, 10)
	T:Advance(9)
	local Young = Map:GetAsync("k")
	T:Advance(2)
	local Old = Map:GetAsync("k")

	Map:SetAsync("z", 1, 0)
	local Seen: any = "unset"
	Map:UpdateAsync("z", function(Current: any): any
		Seen = Current
		return nil
	end, MINUTE)

	T:Is("the item one second before it runs out", Young, 1)
	T:Is("the item one second after", Old, nil)
	T:Is("an item written to live for no time", Map:GetAsync("z"), nil)
	T:Is("what a transform sees on a key that ran out", Seen, nil)
end)

Cases.Case("an expiry has to be a number of seconds inside the window the service allows", function(T: Case)
	local Map = Fresh(T):GetHashMap("Expiry")

	Refused(T, "no expiry", function()
		(Map :: any):SetAsync("k", 1)
	end)
	Refused(T, "a negative expiry", function()
		Map:SetAsync("k", 1, -1)
	end)
	Refused(T, "an expiry past the cap", function()
		Map:SetAsync("k", 1, MemoryStore.MAX_EXPIRY + 1)
	end)
	Refused(T, "an update with no expiry", function()
		(Map :: any):UpdateAsync("k", function(): any
			return 1
		end)
	end)
	T:Holds("an expiry at the cap", function()
		Map:SetAsync("k", 1, MemoryStore.MAX_EXPIRY)
	end)
	T:Holds("a fraction of a second", function()
		Map:SetAsync("k", 1, 1.5)
	end)
end)

Cases.Case("a key is one to 128 bytes with none below a space", function(T: Case)
	local Map = Fresh(T):GetHashMap("Keys")

	Refused(T, "an empty key", function()
		Map:SetAsync("", 1, MINUTE)
	end)
	Refused(T, "a key past the cap", function()
		Map:SetAsync(string.rep("a", MemoryStore.MAX_KEY + 1), 1, MINUTE)
	end)
	Refused(T, "a key past the cap on a read", function()
		Map:GetAsync(string.rep("a", MemoryStore.MAX_KEY + 1))
	end)
	Refused(T, "a key holding a NUL", function()
		Map:SetAsync("a\0b", 1, MINUTE)
	end)
	Refused(T, "a key holding a tab", function()
		Map:SetAsync("a\tb", 1, MINUTE)
	end)
	Refused(T, "a key that is a number", function()
		(Map :: any):SetAsync(5, 1, MINUTE)
	end)
	T:Holds("a key at the cap", function()
		Map:SetAsync(string.rep("a", MemoryStore.MAX_KEY), 1, MINUTE)
	end)
	T:Holds("a key holding a space, a slash, a colon and a hash", function()
		Map:SetAsync("a b/c:d#e", 1, MINUTE)
	end)
	T:Holds("a key holding utf8 past ascii", function()
		Map:SetAsync("ключ", 1, MINUTE)
	end)
end)

Cases.Case("an item is at most 32 KB of json and has to read back as it went in", function(T: Case)
	local Map = Fresh(T):GetHashMap("Items")

	T:Holds("a string that is exactly the cap once quoted", function()
		Map:SetAsync("fits", string.rep("x", MemoryStore.MAX_ITEM - 2), MINUTE)
	end)
	Refused(T, "a string one byte over once quoted", function()
		Map:SetAsync("fat", string.rep("x", MemoryStore.MAX_ITEM - 1), MINUTE)
	end)
	Refused(T, "nothing at all", function()
		(Map :: any):SetAsync("nothing", nil, MINUTE)
	end)
	Refused(T, "a buffer", function()
		Map:SetAsync("buf", buffer.create(4), MINUTE)
	end)
	Refused(T, "a function", function()
		Map:SetAsync("fn", function() end, MINUTE)
	end)
	Refused(T, "a table mixing array and string keys", function()
		Map:SetAsync("mixed", { 1, 2, X = 3 }, MINUTE)
	end)
	Refused(T, "a sparse array", function()
		Map:SetAsync("sparse", { [1] = 1, [3] = 3 }, MINUTE)
	end)
	Refused(T, "nan", function()
		Map:SetAsync("nan", { N = 0 / 0 }, MINUTE)
	end)

	local Nested = { A = { B = { "x", 1.5, true } }, N = 2 ^ 40, Off = false }
	Map:SetAsync("nested", Nested, MINUTE)
	local Back = Map:GetAsync("nested")

	T:Is("a nested table's inner string", Back.A.B[1], "x")
	T:Is("a nested table's fraction", Back.A.B[2], 1.5)
	T:Is("a nested table's boolean", Back.A.B[3], true)
	T:Is("a nested table's large whole number", Back.N, 2 ^ 40)
	Map:SetAsync("off", false, MINUTE)

	T:Is("a false that came back", Back.Off, false)
	T:Is("a bare false as the whole item", Map:GetAsync("off"), false)
end)

Cases.Case("a transform sees the item, makes one when it returns a value, and writes nothing when it returns nil", function(T: Case)
	local Map = Fresh(T):GetHashMap("Transforms")

	local Seen: any = "unset"
	local Made = Map:UpdateAsync("k", function(Current: any): any
		Seen = Current
		return { N = 1 }
	end, MINUTE)

	local Bumped = Map:UpdateAsync("k", function(Current: any): any
		return { N = Current.N + 1 }
	end, MINUTE)

	local Left = Map:UpdateAsync("k", function(_Current: any): any
		return nil
	end, MINUTE)

	T:Is("what the transform saw on an absent key", Seen, nil)
	T:Is("what the first update handed back", Made.N, 1)
	T:Is("what the second update handed back", Bumped.N, 2)
	T:Is("what an update that returned nil handed back", Left, nil)
	T:Is("what is on the key after the nil", (Map:GetAsync("k") :: any).N, 2)
end)

Cases.Case("a transform that yields or throws is refused and the item is left alone", function(T: Case)
	local Map = Fresh(T):GetHashMap("Refusing")
	Map:SetAsync("k", { N = 0 }, MINUTE)

	local Yielded, WhyYield = pcall(function()
		Map:UpdateAsync("k", function(_Current: any): any
			task.wait()
			return { N = 1 }
		end, MINUTE)
	end)
	local Threw, WhyThrow = pcall(function()
		Map:UpdateAsync("k", function(_Current: any): any
			error("boom")
		end, MINUTE)
	end)

	T:Is("a transform that waits", Yielded, false)
	T:Ok("it said the transform yielded", string.find(tostring(WhyYield), "yielded", 1, true) ~= nil)
	T:Is("a transform that throws", Threw, false)
	T:Ok("it said the transform threw", string.find(tostring(WhyThrow), "threw", 1, true) ~= nil)
	T:Is("the item after both", (Map:GetAsync("k") :: any).N, 0)
end)

Cases.Case("a transform runs again when another write lands between its read and its write", function(T: Case)
	local Service = Fresh(T)
	local Map = Service:GetHashMap("Meeting")
	Map:SetAsync("k", { N = 1, Who = "start" }, MINUTE)

	local Runs = 0
	local Final: any = nil
	T:Race({
		function()
			Final = Map:UpdateAsync("k", function(Current: any): any
				Runs += 1
				return { N = Current.N + 10, Who = Current.Who }
			end, MINUTE)
		end,
		function()
			Map:SetAsync("k", { N = 5, Who = "other" }, MINUTE)
		end,
	})

	T:Is("times the transform ran", Runs, 2)
	T:Is("conflicts the service counted", Service.Conflicts, 1)
	T:Is("the sum the transform built on", Final.N, 15)
	T:Is("whose write the transform saw", Final.Who, "other")
end)

Cases.Case("removing an item takes it off and removing a missing one is not an error", function(T: Case)
	local Map = Fresh(T):GetHashMap("Removing")
	Map:SetAsync("k", 1, MINUTE)
	Map:RemoveAsync("k")

	T:Is("the key after the remove", Map:GetAsync("k"), nil)
	T:Holds("removing a key nothing wrote", function()
		Map:RemoveAsync("never")
	end)
end)

Cases.Case("a get, a set and a remove cost one unit and an update costs two", function(T: Case)
	local Service = Fresh(T)
	local Map = Service:GetHashMap("Units")

	Map:GetAsync("k")
	Map:SetAsync("k", 1, MINUTE)
	Map:UpdateAsync("k", function(Current: any): any
		return Current + 1
	end, MINUTE)
	Map:RemoveAsync("k")

	T:Is("units spent on the four calls", Service.Units, MemoryStore.UNIT * 3 + MemoryStore.UPDATE_UNITS)
end)

Cases.Case("the units of an empty experience run out at the quota and come back with the window", function(T: Case)
	local Service = Fresh(T, { Players = 0, CCU = 0 })
	local Map = Service:GetHashMap("Quota")

	for _ = 1, MemoryStore.QUOTA_BASE do
		Map:GetAsync("k")
	end
	local Starved = Refuses(function()
		Map:GetAsync("k")
	end)

	T:Advance(Datastore.REFILL_WINDOW)
	local Back = Refuses(function()
		Map:GetAsync("k")
	end)

	T:Ok("the call past the quota", Starved)
	T:No("a call once the window refilled", Back)
	T:Is("units counted whether or not they were refused", Service.Units, MemoryStore.QUOTA_BASE + 2)
end)

Cases.Case("a write past the memory quota is refused and a read is not, and taking an item back makes room", function(T: Case)
	local Service = Fresh(T, { Players = 0, CCU = 0 })
	local Map = Service:GetHashMap("Memory")
	local Room = Service:Memory()

	local Held = 0
	local Full = false
	for Index = 1, 1000 do
		if Refuses(function()
			Map:SetAsync(`k{Index}`, string.rep("a", 128), MINUTE)
		end) then
			Full = true
			break
		end
		Held += 1
	end

	local Read = Refuses(function()
		Map:GetAsync("k1")
	end)

	Map:RemoveAsync("k1")
	local After = Refuses(function()
		Map:SetAsync("last", string.rep("a", 128), MINUTE)
	end)

	T:Ok("items it took before the quota bit", Held > 0)
	T:Ok("a write with no room left", Full)
	T:No("a read with no room left", Read)
	T:No("a write once an item was taken back", After)
	T:Ok("bytes it counts, inside the quota", Service.Bytes <= Room)
	T:Ok("the high water mark it kept", Service.Peak >= Service.Bytes)
end)

Cases.Case("an item that ran out gives its memory back without anyone reading it", function(T: Case)
	local Service = Fresh(T, { Players = 0, CCU = 0 })
	local Map = Service:GetHashMap("Aging")

	Map:SetAsync("brief", string.rep("a", 256), 10)
	local While = Service.Bytes

	T:Advance(11)
	local Stale = Service.Bytes
	Service:Reclaim()

	T:Ok("bytes it counted while the item was live", While > 0)
	T:Is("bytes before anyone looked, since nothing sweeps on the clock", Stale, While)
	T:Is("bytes once the service reclaimed", Service.Bytes, 0)
end)

Cases.Case("one map runs out of units at its own ceiling while the experience still has plenty", function(T: Case)
	local Service = Fresh(T, { Players = 0, CCU = 2000 })
	local Busy = Service:GetHashMap("Hot")
	local Quiet = Service:GetHashMap("Cold")

	for _ = 1, MemoryStore.QUOTA_MAP do
		Busy:GetAsync("k")
	end
	local Stopped = Refuses(function()
		Busy:GetAsync("k")
	end)
	local Beside = Refuses(function()
		Quiet:GetAsync("k")
	end)

	T:Advance(Datastore.REFILL_WINDOW)
	local Back = Refuses(function()
		Busy:GetAsync("k")
	end)

	T:Ok("the call past one map's ceiling", Stopped)
	T:No("a call on the map beside it, which the experience quota still covers", Beside)
	T:No("a call once the window refilled", Back)
	T:Is("units the busy map spent, counted whether or not they were refused", Service.Spent.Hot, MemoryStore.QUOTA_MAP + 2)
end)

Cases.Case("a map name is one to 128 characters, one name is one map, and two hooks over one service share it", function(T: Case)
	local Service = Fresh(T)

	Refused(T, "an empty name", function()
		Service:GetHashMap("")
	end)
	Refused(T, "a name past the cap", function()
		Service:GetHashMap(string.rep("n", MemoryStore.MAX_NAME + 1))
	end)
	T:Holds("a name at the cap", function()
		Service:GetHashMap(string.rep("n", MemoryStore.MAX_NAME))
	end)
	T:Ok("the same name twice", Service:GetHashMap("Same") == Service:GetHashMap("Same"))

	local Left = Memory.New(T.Turn, nil, Service)
	local Right = Memory.New(T.Turn, nil, Service)
	Left.Cache("Shared"):SetAsync("k", 7, MINUTE)

	T:Is("what the other hook reads", Right.Cache("Shared"):GetAsync("k"), 7)
	T:Ok("the bench hook carries a cache", T.Hook.Cache ~= nil)
end)

Cases.Case("the wrapper answers a live map and answers a miss when the map does not", function(T: Case)
	local Held = Wrapper.New("Ledger_Lease", T.Turn, T.Hook)

	local Set = Held:SetAsync("k", { N = 1 }, MINUTE)
	local Read, Value = Held:GetAsync("k")
	local Updated, Next = Held:UpdateAsync("k", function(Current: any): any
		return { N = Current.N + 1 }
	end, MINUTE)
	local Removed = Held:RemoveAsync("k")
	local Again, Gone = Held:GetAsync("k")

	T:Ok("a set", Set)
	T:Ok("a read", Read)
	T:Is("what the read gave", Value.N, 1)
	T:Ok("an update", Updated)
	T:Is("what the update gave", Next.N, 2)
	T:Ok("a remove", Removed)
	T:Ok("a read of nothing still answers", Again)
	T:Is("and gives nothing", Gone, nil)
	T:Is("calls the wrapper counted", Held.Spent, 5)
	T:Is("misses the wrapper counted", Held.Missed, 0)

	local Missing = Wrapper.New("Ledger_Lease", T.Turn, Broken(T))

	local Ok, Nothing = Missing:GetAsync("k")
	local Wrote = Missing:SetAsync("k", 1, MINUTE)
	local Changed = Missing:UpdateAsync("k", function(): any
		return 1
	end, MINUTE)
	local Took = Missing:RemoveAsync("k")

	T:No("a read of a map that is down", Ok)
	T:Is("and it gives nothing", Nothing, nil)
	T:No("a set of a map that is down", Wrote)
	T:No("an update of a map that is down", Changed)
	T:No("a remove of a map that is down", Took)
	T:Is("misses counted, the three it made before it stopped calling", Missing.Missed, 3)
	T:Is("calls counted", Missing.Spent, 3)
	T:Warns("it said the map did not answer on the first miss", "1 miss(es) since", 1)

	T:Advance(Suite.Horizons.BREAKER + Suite.Horizons.AUTOSAVE + 1)
	T:No("a read once the window has passed", (Missing:GetAsync("k")))
	T:Is("calls counted once it tried again", Missing.Spent, 4)
	T:Warns("it said how many misses it swallowed since", "3 miss(es) since", 1)
	T:Warns("it said so once per window and not once per miss", "did not answer", 2)
end)

Cases.Case("a map that misses three times over is left alone until the window passes", function(T: Case)
	local Missing = Wrapper.New("Ledger_Lease", T.Turn, Broken(T))

	for _ = 1, 3 do
		Missing:GetAsync("k")
	end
	local Shut = Missing.Spent
	for _ = 1, 10 do
		T:No("a read while the map is left alone", (Missing:GetAsync("k")))
	end

	T:Is("calls it made before it stopped", Shut, 3)
	T:Is("calls it made after that", Missing.Spent - Shut, 0)

	T:Advance(Suite.Horizons.BREAKER + 1)
	T:No("a read once the window has passed", (Missing:GetAsync("k")))
	T:Is("calls it made once it tried again", Missing.Spent - Shut, 1)
end)

Cases.Case("an answer between misses keeps a map being called", function(T: Case)
	local Turns = 0
	local Flaky: Engine.Map = {
		GetAsync = function(_: any, _Key: string): any
			Turns += 1
			if Turns % 2 == 1 then
				error("the map is down", 0)
			end
			return Turns
		end,
		SetAsync = function(_: any, _Key: string, _Value: any, _Expiry: number): any
			return nil
		end,
		UpdateAsync = function(_: any, _Key: string, _Transform: (any) -> any, _Expiry: number): any
			return nil
		end,
		RemoveAsync = function(_: any, _Key: string) end,
	}
	local Held = Wrapper.New("Ledger_Lease", T.Turn, {
		Open = T.Hook.Open,
		Budget = T.Hook.Budget,
		Cache = function(_Name: string): Engine.Map
			return Flaky
		end,
	})

	for _ = 1, 20 do
		Held:GetAsync("k")
	end

	T:Is("calls it made, every one of them", Held.Spent, 20)
	T:Is("misses among them", Held.Missed, 10)
end)

Cases.Case("a map that is left alone leaves the other maps alone", function(T: Case)
	local Down = Broken(T)
	local Live = Wrapper.New("Ledger_Tally", T.Turn, T.Hook)
	local Missing = Wrapper.New("Ledger_Lease", T.Turn, Down)

	for _ = 1, 3 do
		Missing:GetAsync("k")
	end
	T:No("a read of the map that is down", (Missing:GetAsync("k")))
	T:Ok("a read of the map beside it", (Live:GetAsync("k")))
	T:Ok("a write to the map beside it", Live:SetAsync("k", 1, MINUTE))

	T:Is("calls the map that is down made", Missing.Spent, 3)
	T:Is("calls the map beside it made", Live.Spent, 2)
	T:Is("misses the map beside it counted", Live.Missed, 0)
end)

Cases.Case("the wrapper calls once, and keeps writes to one key in order", function(T: Case)
	local Held = Wrapper.New("Ledger_Order", T.Turn, T.Hook)

	local Runs = 0
	local Ok = Held:UpdateAsync("k", function(): any
		Runs += 1
		error("boom")
	end, MINUTE)

	T:No("an update whose transform threw", Ok)
	T:Is("times the transform ran", Runs, 1)

	local Yielded = Held:UpdateAsync("k", function(): any
		task.wait()
		return 1
	end, MINUTE)
	T:No("an update whose transform yielded", Yielded)

	T:Race({
		function()
			Held:UpdateAsync("k", function(): any
				return "first"
			end, MINUTE)
		end,
		function()
			Held:SetAsync("k", "second", MINUTE)
		end,
	})
	local _, Queued = Held:GetAsync("k")

	local Loose = Wrapper.New("Ledger_Loose", T.Turn, T.Hook)
	Loose.Direct = true
	T:Race({
		function()
			Loose:UpdateAsync("k", function(): any
				return "first"
			end, MINUTE)
		end,
		function()
			Loose:SetAsync("k", "second", MINUTE)
		end,
	})
	local _, Direct = Loose:GetAsync("k")

	T:Is("the item once both writes queued on the key", Queued, "second")
	T:Is("the item when the calls went straight through", Direct, "first")
end)

Cases.Case("a cache call inside a reducer is refused as a yield, which is the guard", function(T: Case)
	local Suite = Suite
	local Reducers = Suite.Reducers
	local Store = T:Store({
		Default = Reducers.COINS,
		Field = "Coins",
		Reducer = function(State: any, Op: any): any
			if Op.Kind == "Peek" then
				T.Hook.Cache("Ledger_Lease"):GetAsync("k")
			end
			return Reducers.Vaulter(State, Op)
		end,
	})

	local Ok, Why = Store.Store:Edit("k", "Peek"):Wait()
	local Active = Store:Session("k")
	local Says = T:Throws("a hopeful apply whose reducer reaches the cache", function()
		Active:Apply("Peek")
	end)

	T:No("an edit whose reducer reaches the cache", Ok)
	T:Is("the reason", Why, Suite.Reasons.Refused)
	T:Ok("the apply named the yield", Says ~= nil and string.find(Says :: string, "without yielding", 1, true) ~= nil)
	T:Is("the key, untouched", Store:Amount("k", "Coins"), 0)
end)

Cases.Case("a map that stays down costs one call a window, however long it is down", function(T: Case)
	local Missing = Wrapper.New("Ledger_Lease", T.Turn, Broken(T))

	for _ = 1, 3 do
		Missing:GetAsync("k")
	end
	local Shut = Missing.Spent
	T:Is("the calls it made before it stopped", Shut, 3)

	for Window = 1, 3 do
		T:Advance(Suite.Horizons.BREAKER + 1)
		for _ = 1, 5 do
			T:No("a read while the map is down", (Missing:GetAsync("k")))
		end
		T:Is(`the probes it has made after {Window} window(s)`, Missing.Spent - Shut, Window)
	end
end)

return Cases
