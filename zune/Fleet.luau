--!strict

--[=[

	Fleet: Runs the MemoryStore features against a fleet of servers on the mock and prints the cost.

	N servers over one datastore and one MemoryStore, driven at their real cadence on the virtual
	clock. Every server reaps once per ten minutes, sweeps once a minute and draws a pot every five
	seconds. Thirty two of them contend on one bank key, and each holds a shelf a buyer checks out
	from.

	It prints datastore calls, MemoryStore units and memory for each. The cache runs as it is, absent,
	failing every call, or partial, where reads answer and writes do not. The before and after are
	measured rather than worked out.

	A third word runs only the rows whose name holds it.

	Return type: Nothing. It prints.
	Example usage:
		zune run zune/Fleet.luau 5000
		zune run zune/Fleet.luau 5000 absent
		zune run zune/Fleet.luau 5000 "" follow
--]=]

local Engine = require("./Engine")

Engine.Install()

local Suite = require("../tests/Suite")
local Case = require("../tests/Suite/Case")
local Ledger = require("../src") :: any
local Wrapper = require("../src/Util/DataStoreWrapper")
local Bookings = require("../src/Core/Constants/Bookings")
local Datastore = require("../src/Core/Constants/Datastore")
local Follows = require("../src/Core/Constants/Follows")
local Measure = require("../src/Encode/Measure")
local MemoryStore = require("../src/Core/Constants/MemoryStore")
local Messages = require("../src/Core/Constants/Messages")
local Shards = require("../src/Core/Constants/Shards")
local Sweeper = require("../src/Store/Sweeper")
local Transactions = require("../src/Core/Constants/Transactions")
local Windows = require("../src/Core/Constants/Windows")

local Fault = Suite.Fault

Engine.Listen(Suite.Heard)

local SERVERS = tonumber(zune.process.args[2]) or 1000
local MODE = zune.process.args[3]
local ROW = zune.process.args[4]
local MINUTES = 10
local HOUR = 60
local CONTENDERS = math.min(32, SERVERS)
local POT_TICK = 5
local PLAYERS = 20
local HOLD_TICKS = 12
local START = 100
local CHAOS_SERVERS = 200
local CHAOS_DROP = 0.03
local CHAOS_STALL = 0.02
local CHAOS_TX = 3
local IDLE_MINUTES = 10
local IDLE_WRITES = 200
local CONFIG_ROLES = 100
local CONFIG_ROLE_BYTES = 30
local ROLL_TRANSACTIONS = 20000
local ACCUSED = Messages.ACCUSED

type Fixture = Suite.Fixture

Suite.Cache(if MODE == "" then nil else MODE :: any)
Suite.Watch(false)

local function Row(Label: string, Calls: number, Units: number, Per: string)
	print(string.format("  %-58s %10d calls %10d units   %s", Label, Calls, Units, Per))
end

local function Taken(T: Suite.Case): { [string]: number }
	return table.clone(T.Service.Spent)
end

local function Ceilings(T: Suite.Case, Before: { [string]: number }, Minutes: number)
	local Names: { string } = {}
	for Name in T.Service.Spent do
		table.insert(Names, Name)
	end
	table.sort(Names)

	for _, Name in Names do
		local Rate = (T.Service.Spent[Name] - (Before[Name] or 0)) / Minutes
		if Rate <= 0 then
			continue
		end
		print(string.format("    %s: %d units a minute against a ceiling of %d for one map, %s", Name, Rate, MemoryStore.QUOTA_MAP, if Rate > MemoryStore.QUOTA_MAP then "OVER" else "inside"))
	end

	local Room = MemoryStore.MEMORY_BASE + MemoryStore.MEMORY_PER_USER * SERVERS * PLAYERS
	print(string.format("    memory: %d bytes at its highest against a quota of %d for %d players, %s", T.Service.Peak, Room, SERVERS * PLAYERS, if T.Service.Peak > Room then "OVER" else "inside"))
end

local function Calls(Servers: { Fixture }): number
	local Total = 0
	for _, Held in Servers do
		Total += Held.Store.Wrapper.Spent + Held.Store.TxWrapper.Spent
	end
	return Total
end

local function Fleet(T: Suite.Case, Count: number): { Fixture }
	local Servers: { Fixture } = {}
	for Index = 1, Count do
		Servers[Index] = T:Bank(`n{Index}`)
	end
	return Servers
end

local function Homes(T: Suite.Case, Count: number): { Fixture }
	local Servers: { Fixture } = {}
	for Index = 1, Count do
		Servers[Index] = T:Store({ Keys = "Player", Default = Suite.Reducers.MONEY, Reducer = Suite.Reducers.Banker, Balance = "Gold", Node = `n{Index}` })
	end
	return Servers
end

local function Funded(Held: Fixture, A: string, B: string)
	Held:Seed(A, { Gold = START, Touches = 0 })
	Held:Seed(B, { Gold = 0, Touches = 0 })
end

local function Move(Held: Fixture, A: string, B: string, Amount: number, Id: string): boolean
	return (Held.Store
		:Tx(Id, {
			{ Key = A, Kind = "Give", Fields = { Amount = -Amount } },
			{ Key = B, Kind = "Give", Fields = { Amount = Amount } },
		})
		:Wait())
end

local function Bench(Name: string, Body: (Suite.Case) -> ())
	if ROW ~= nil and ROW ~= "" and string.find(Name, ROW, 1, true) == nil then
		return
	end

	local T = Case.Open(Name)
	local Started = os.clock()
	local Raised = Case.Drive(T, Body)
	if Raised ~= nil then
		print(`  {Name} threw: {Raised}`)
	end
	for _, Says in T.Broken do
		print(`  {Name} broke: {Says}`)
	end
	local Accused = 0
	for _, Held in T.Records do
		if string.find(Held.Says, ACCUSED, 1, true) ~= nil then
			Accused += Held.Count
		end
	end
	if Accused > 0 then
		print(`  {Name}: Ledger accused itself {Accused} time(s)`)
	end
	Case.Close(T)
	print(string.format("  %.1fs", os.clock() - Started))
end

local function Chaos(Held: Fixture)
	local Turn = Held.Store.Wrapper.Scheduler
	for _, Method in { "GetAsync", "UpdateAsync", "RemoveAsync", "ListKeysAsync", "SetAsync" } do
		for _, Name in { Held.Data, Held.Marked, Transactions.LEASE_MAP, Shards.MAP, Bookings.MAP, Follows.MAP } do
			Held.Hook.Fail(Fault.On(Method):OnStore(Name):Meddle(function()
				local Roll = math.random()
				if Roll < CHAOS_DROP then
					error("chaos: the call was dropped", 0)
				end
				if Roll < CHAOS_DROP + CHAOS_STALL then
					Turn.Wait(1 + math.random() * 2)
				end
			end))
		end
	end
end

local function Settled(T: Suite.Case, Servers: { Fixture }, Keys: { string })
	for _, Held in Servers do
		Held:Healed()
	end
	for _ = 1, 4 do
		T:Advance(Windows.REAP + Windows.TX)
		Servers[1].Store:ReapMarkers()
		for _, Key in Keys do
			Servers[1].Store:Resettle(Key):Wait()
		end
	end
end

local function Bare(T: Suite.Case, Index: number, Data: string, Cache: boolean): any
	local Hook: any = { Open = T.Hook.Open, Budget = T.Hook.Budget, Cache = if Cache then T.Hook.Cache else nil }
	local Built = Ledger.New({
		Name = `Mixed{Index}`,
		Hook = Hook,
		Keys = "String",
		Default = Suite.Reducers.MONEY,
		Balance = "Gold",
		Reducer = Suite.Reducers.Banker,
	})
	local Turn = T.Turn
	Built.Wrapper = Wrapper.New(Data, Turn, Hook)
	Built.TxWrapper = Wrapper.New(`{Data}_Tx`, Turn, Hook)
	Built.Wrapper.Attempts, Built.Wrapper.Constant, Built.Wrapper.Exponent, Built.Wrapper.Jitter = 3, 0, 0, 0
	Built.TxWrapper.Attempts, Built.TxWrapper.Constant, Built.TxWrapper.Exponent, Built.TxWrapper.Jitter = 3, 0, 0, 0
	Built.Books, Built.Shaped = nil, nil
	Built.Node = `m{Index}`
	return Built
end

print(`\n~~~~~~~~~~~~ Ledger fleet, {SERVERS} servers, MemoryStore {MODE or "on"} ~~~~~~~~~~~~`)

Bench("reap", function(T: Suite.Case)
	local Servers = Fleet(T, SERVERS)
	Funded(Servers[1], "reapA", "reapB")
	Move(Servers[1], "reapA", "reapB", 10, "reap1")
	T:Advance(Windows.REAP + 60)

	local Before, Units = Calls(Servers), T.Service.Units
	for _ = 1, MINUTES do
		for Index = 1, SERVERS do
			Servers[Index].Store:ReapMarkers(1)
		end
		T:Advance(Windows.SWEEP)
	end

	local Spent = Calls(Servers) - Before
	Row(`reaping, one shard a server a minute over {MINUTES} minutes`, Spent, T.Service.Units - Units, string.format("%.1f calls per server", Spent / SERVERS))
end)

Bench("roll", function(T: Suite.Case)
	local Servers = Fleet(T, SERVERS)
	local function Plenty(): number
		return 1000
	end
	for Index, Held in Servers do
		Held:Budget(Plenty)
		Held:MarkerBudget(Plenty)
		Funded(Held, `rollA{Index}`, `rollB{Index}`)
	end

	local Minutes = math.clamp(ROLL_TRANSACTIONS // SERVERS, 2, MINUTES)
	local Before, Units = Calls(Servers), T.Service.Units
	local Told = 0
	for Minute = 1, Minutes do
		for Index, Held in Servers do
			if Move(Held, `rollA{Index}`, `rollB{Index}`, 1, `roll{Index}m{Minute}`) then
				Told += 1
			end
		end
		T:Advance(Windows.SWEEP)
	end
	local Wrote = Calls(Servers) - Before

	local Marks = Servers[1].DirectMarks
	local RollKeys = 0
	for _, Name in Marks.Names do
		if Marks.Slots[Name].Live ~= nil and string.sub(Name, 1, #Transactions.RESERVED) == Transactions.RESERVED then
			RollKeys += 1
		end
	end
	local Markers = #Servers[1]:Marks()

	T:Advance(Windows.REAP_GRACE + 60)
	local ReapBefore, ReapUnits = Calls(Servers), T.Service.Units
	local ListsBefore = T.Service.Calls.ListAsync or 0
	local Rounds, Reaped = 0, 0
	repeat
		Rounds += 1
		for _, Held in Servers do
			Reaped += Held.Store:ReapMarkers(1)
		end
		T:Advance(Windows.SWEEP)
	until Reaped >= Markers or Rounds >= 6
	local ReapSpent = Calls(Servers) - ReapBefore
	local Listed = (T.Service.Calls.ListAsync or 0) - ListsBefore
	local Left = #Servers[1]:Marks()
	local ListBudget = 300 + 2 * SERVERS * PLAYERS

	Row(
		`every server running one transaction a minute for {Minutes} minutes`,
		Wrote,
		T.Service.Units - Units,
		string.format("%d of %d told yes, %.1f calls per transaction", Told, SERVERS * Minutes, Wrote / math.max(Told, 1))
	)
	print(string.format("    roll keys: %d live, %.1f per shard per minute, %.1f names each", RollKeys, RollKeys / (Transactions.SHARDS * Minutes), Markers / math.max(RollKeys, 1)))
	Row(`then reaping, one shard a server a minute, {Rounds} round(s)`, ReapSpent, T.Service.Units - ReapUnits, string.format("%d of %d markers reaped, %d left", Reaped, Markers, Left))
	print(
		string.format(
			"    lists: %d in %d round(s), %.1f per pass against a 20 player server's %d a minute, %d a minute fleet wide against an experience budget of %d, %s",
			Listed,
			Rounds,
			Listed / (Rounds * SERVERS),
			5 + 2 * PLAYERS,
			Listed // Rounds,
			ListBudget,
			if Listed // Rounds > ListBudget then "OVER" else "inside"
		)
	)
end)

Bench("sweep", function(T: Suite.Case)
	local Servers = Fleet(T, SERVERS)
	Servers[1]:Write("restA", {
		Snapshot = { Gold = 60, Touches = 0, _Held = { rest1 = { To = "restB", Amount = 40, At = T:Now() - Windows.REDRIVE - 1 } } },
		Ops = {},
		Seen = {},
	})

	local Sweeps: { Sweeper.Sweeper } = {}
	for Index, Held in Servers do
		local Sweep = Sweeper.New()
		Sweep:Add(Held.Store:Swept(), "restA")
		Sweeps[Index] = Sweep
	end

	local Before, Units = Calls(Servers), T.Service.Units
	for _ = 1, MINUTES do
		for _, Sweep in Sweeps do
			Sweep:Pass()
		end
		T:Advance(Windows.SWEEP)
	end
	for _, Sweep in Sweeps do
		Sweep:Stop()
	end

	local Spent = Calls(Servers) - Before
	Row(`sweeping one key every server follows, {MINUTES} passes each`, Spent, T.Service.Units - Units, string.format("%.2f repairs per key per minute", Spent / MINUTES))
end)

Bench("idle", function(T: Suite.Case)
	local Servers = Homes(T, SERVERS)
	for Index, Held in Servers do
		Held:Seed(tostring(Index), { Gold = START, Touches = 0 })
		Held.Store:Load(T:Player(Index))
	end

	local Maps = Taken(T)
	local Before, Units = Calls(Servers), T.Service.Units
	for _ = 1, MINUTES do
		T:Wait(Windows.SWEEP)
	end
	local Spent, SpentUnits = Calls(Servers) - Before, T.Service.Units - Units

	local Sessions: { any } = {}
	for Index, Held in Servers do
		Sessions[Index] = Held.Store:Expect(T:Player(Index))
	end
	T:Wait(Windows.AUTOSAVE)
	local Written = 0
	for Index = 2, SERVERS do
		if Servers[1].Store:Edit(Index, "Fund", { Amount = 5 }):Wait() then
			Written += 1
		end
	end
	local Started = T:Now()
	local Seen: { number } = {}
	local Left = SERVERS - 1
	T:Until(function(): boolean
		local Now = T:Now()
		for Index = 2, SERVERS do
			if Seen[Index] == nil and Sessions[Index]:Get().Gold == START + 5 then
				Seen[Index] = Now - Started
				Left -= 1
			end
		end
		return Left == 0
	end)
	local Total, Worst = 0, 0
	for _, Took in Seen do
		Total += Took
		Worst = math.max(Worst, Took)
	end

	Row(
		`an idle player on every server for {MINUTES} minutes`,
		Spent,
		SpentUnits,
		string.format("%.2f reads and %.2f units per player per minute", Spent / SERVERS / MINUTES, SpentUnits / SERVERS / MINUTES)
	)
	print(string.format("    %d writes from another server were seen by the idle sessions after %.1fs on average and %.1fs at worst", Written, Total / math.max(#Seen, 1), Worst))
	Ceilings(T, Maps, MINUTES)
end)

Bench("idle chaos", function(T: Suite.Case)
	local Servers = Homes(T, SERVERS)
	local Lives: { any } = {}
	for Index, Held in Servers do
		Held:Seed(tostring(Index), { Gold = START, Touches = 0 })
		Held.Store:Load(T:Player(Index))
		Lives[Index] = Held.Store:Expect(T:Player(Index))
		Chaos(Held)
	end

	local Want: { number } = table.create(SERVERS, 0)
	local Since: { number } = {}
	local Worst, Writes, Landed = 0, 0, 0
	local Before, Units = Calls(Servers), T.Service.Units
	for Half = 1, IDLE_MINUTES * 2 do
		if Half % 2 == 1 then
			for _ = 1, IDLE_WRITES do
				local Target = math.random(SERVERS)
				Writes += 1
				if Servers[math.random(SERVERS)].Store:Edit(Target, "Fund", { Amount = 1 }):Wait() then
					Landed += 1
					Want[Target] += 1
					if Since[Target] == nil then
						Since[Target] = T:Now()
					end
				end
			end
		end
		T:Wait(Windows.AUTOSAVE)

		local Now = T:Now()
		for Index, Live in Lives do
			local Gold = Live:Get().Gold
			if Gold > START + Want[Index] then
				Want[Index] = Gold - START
			end
			local Started = Since[Index]
			if Started ~= nil and Gold >= START + Want[Index] then
				Worst = math.max(Worst, Now - Started)
				Since[Index] = nil
			end
		end
	end
	local Spent, SpentUnits = Calls(Servers) - Before, T.Service.Units - Units

	for _, Held in Servers do
		Held:Healed()
	end
	T:Wait(Windows.AUTOSAVE * 6)

	local Stored, Wrong = 0, 0
	for Index, Held in Servers do
		local Gold = Held:Amount(tostring(Index))
		Stored += Gold
		if Lives[Index]:Get().Gold ~= Gold then
			Wrong += 1
		end
	end
	local Floor, Ceiling = START * SERVERS + Landed, START * SERVERS + Writes

	Row(
		`{SERVERS} idle players under {IDLE_MINUTES} minutes of {math.floor(CHAOS_DROP * 100)}% drops and {math.floor(CHAOS_STALL * 100)}% stalls`,
		Spent,
		SpentUnits,
		string.format("%.2f reads and %.2f units per player per minute", Spent / SERVERS / IDLE_MINUTES, SpentUnits / SERVERS / IDLE_MINUTES)
	)
	print(`    money: {Stored} on the keys against {Landed} of {Writes} writes told yes, {if Stored >= Floor and Stored <= Ceiling then "whole" else "WRONG"}`)
	print(`    sessions that do not match their key once settled: {Wrong} of {SERVERS}, worst lag between a write and the session showing it {Worst}s`)
end)

Bench("totals", function(T: Suite.Case)
	local Servers = Fleet(T, SERVERS)
	local Maps = Taken(T)
	local Before, Units = Calls(Servers), T.Service.Units
	local Ticks = Windows.SWEEP // POT_TICK
	for Tick = 1, Ticks do
		for Index, Held in Servers do
			if Index % 100 == Tick then
				Held.Store:Bump("pot", "Gold", 1):Wait()
			end
			Held.Store:Total("pot", "Gold"):Wait()
		end
		T:Advance(POT_TICK)
	end

	local Spent = Calls(Servers) - Before
	Row(`a pot every server draws every {POT_TICK}s for a minute`, Spent, T.Service.Units - Units, string.format("%.1f calls per server per minute", Spent / SERVERS))
	Ceilings(T, Maps, 1)
end)

Bench("contention", function(T: Suite.Case)
	local Servers = Fleet(T, CONTENDERS)
	Funded(Servers[1], "bankA", "bankB")

	local Before, Units = Calls(Servers), T.Service.Units
	local Wins = 0
	local Bodies: { () -> () } = {}
	for Index, Held in Servers do
		table.insert(Bodies, function()
			if Move(Held, "bankA", "bankB", 1, `bank{Index}`) then
				Wins += 1
			end
		end)
	end
	T:Race(Bodies)

	local Spent = Calls(Servers) - Before
	Row(`{CONTENDERS} servers on one bank key at once`, Spent, T.Service.Units - Units, string.format("%d of %d went through, %.1f calls per success", Wins, CONTENDERS, Spent / math.max(Wins, 1)))
end)

Bench("holds", function(T: Suite.Case)
	local Servers: { Fixture } = {}
	for Index = 1, SERVERS do
		Servers[Index] = T:Shelf(`h{Index}`)
		Servers[Index]:Seed(`shelf{Index}`, { Stock = 1, Sold = 0, Gold = 0 })
	end

	local Maps = Taken(T)
	local Before, Units = Calls(Servers), T.Service.Units
	local Reserved, Sold = 0, 0
	local Batch = math.ceil(SERVERS / HOLD_TICKS)

	for Tick = 1, HOLD_TICKS do
		for Index = (Tick - 1) * Batch + 1, math.min(Tick * Batch, SERVERS) do
			local Held = Servers[Index]
			if Held.Store:Reserve(`shelf{Index}`, "Stock", 1, `buy{Index}`):Wait() then
				Reserved += 1
				if Held.Store:Confirm(`shelf{Index}`, `buy{Index}`, "Sell", { Count = 1 }):Wait() then
					Sold += 1
				end
			end
		end
		T:Advance(Windows.SWEEP // HOLD_TICKS)
	end

	local Left, Counted = 0, 0
	for Index, Held in Servers do
		local State = Held:State(`shelf{Index}`)
		Left += State.Stock
		Counted += State.Sold
	end

	local Spent = Calls(Servers) - Before
	Row(
		`a shelf on every server, one reservation and one checkout each`,
		Spent,
		T.Service.Units - Units,
		string.format("%.1f calls and %.1f units per purchase", Spent / math.max(Sold, 1), (T.Service.Units - Units) / math.max(Sold, 1))
	)
	print(`    stock: {Sold} sold of {Reserved} held, {Left} left and {Counted} counted, {if Sold == Reserved and Left + Counted == SERVERS then "whole" else "WRONG"}`)
	Ceilings(T, Maps, 1)
end)

Bench("stampede", function(T: Suite.Case)
	local Servers = Fleet(T, SERVERS)
	Servers[1].Store:Bump("pot", "Gold", 5):Wait()

	local function Round(): (number, number)
		local Before, Units = Calls(Servers), T.Service.Units
		local Bodies: { () -> () } = {}
		for _, Held in Servers do
			table.insert(Bodies, function()
				Held.Store:Total("pot", "Gold"):Wait()
			end)
		end
		T:Race(Bodies)
		return Calls(Servers) - Before, T.Service.Units - Units
	end

	local Cold, ColdUnits = Round()
	local Warm, WarmUnits = Round()
	Row("every server's first look at a pot in the same instant", Cold, ColdUnits, string.format("%.1f reads per server", Cold / SERVERS))
	Row("and every server's second look, a moment later", Warm, WarmUnits, string.format("%.1f reads per server", Warm / SERVERS))
end)

Bench("chaos", function(T: Suite.Case)
	local Count = math.min(SERVERS, CHAOS_SERVERS)
	local Servers = Fleet(T, Count)
	local First = Servers[1]
	for _, Held in Servers do
		Chaos(Held)
	end
	Funded(First, "chaosA", "chaosB")
	First:Write("restA", {
		Snapshot = { Gold = 60, Touches = 0, _Held = { rest1 = { To = "restB", Amount = 40, At = T:Now() - Windows.REDRIVE - 1 } } },
		Ops = {},
		Seen = {},
	})

	local Sweeps: { Sweeper.Sweeper } = {}
	for Index, Held in Servers do
		local Sweep = Sweeper.New()
		Sweep:Add(Held.Store:Swept(), "restA")
		Sweeps[Index] = Sweep
	end

	local Tries, Wins, Bumps, Landed = 0, 0, 0, 0
	local Before, Units = Calls(Servers), T.Service.Units
	local Batch = math.ceil(Count / MINUTES)
	for Minute = 1, HOUR do
		local Slot = (Minute - 1) % MINUTES
		for Index = Slot * Batch + 1, math.min((Slot + 1) * Batch, Count) do
			Servers[Index].Store:ReapMarkers()
		end
		for _, Sweep in Sweeps do
			Sweep:Pass()
		end
		for Index, Held in Servers do
			if Index % 50 == Minute % 50 then
				Bumps += 1
				if Held.Store:Bump("pot", "Gold", 1):Wait() then
					Landed += 1
				end
			end
			Held.Store:Total("pot", "Gold"):Wait()
		end
		for Round = 1, CHAOS_TX do
			Tries += 1
			if Move(Servers[math.random(Count)], "chaosA", "chaosB", 1, `chaos{Minute}x{Round}`) then
				Wins += 1
			end
		end
		T:Advance(Windows.SWEEP)
	end
	for _, Sweep in Sweeps do
		Sweep:Stop()
	end
	local Spent, SpentUnits = Calls(Servers) - Before, T.Service.Units - Units

	Settled(T, Servers, { "chaosA", "chaosB" })
	local A, B, Aside = First:Amount("chaosA"), First:Amount("chaosB"), First:Aside("chaosA")
	T:Advance(Windows.TALLY_KEEP + 1)
	local Pot = First.Store:Total("pot", "Gold"):Wait()

	Row(
		`{Count} servers, an hour of {math.floor(CHAOS_DROP * 100)}% drops and {math.floor(CHAOS_STALL * 100)}% stalls on every call`,
		Spent,
		SpentUnits,
		string.format("%.0f calls per server", Spent / Count)
	)
	print(`    money: {A} + {B} + {Aside} set aside = {A + B + Aside}, started at {START}, {if A + B + Aside == START then "whole" else "WRONG"}`)
	print(`    transactions: {Wins} of {Tries} told yes, receiver holds {B}, {if B >= Wins and B <= Tries then "consistent" else "WRONG"}`)
	print(`    pot: {Pot} after {Landed} of {Bumps} bumps told yes, {if Pot ~= nil and Pot >= Landed and Pot <= Bumps then "consistent" else "WRONG"}`)
	print(`    markers left: {#First:Marks()}, keys still parked: {if First:Pending("chaosA") or First:Pending("chaosB") then "yes" else "none"}`)
	print(
		string.format(
			"    memory: %d bytes at its highest against a quota of %d for %d players",
			T.Service.Peak,
			MemoryStore.MEMORY_BASE + MemoryStore.MEMORY_PER_USER * Count * PLAYERS,
			Count * PLAYERS
		)
	)
end)

Bench("follow", function(T: Suite.Case)
	local Servers = Fleet(T, SERVERS)
	local Roles: { [string]: string } = {}
	for Index = 1, CONFIG_ROLES do
		Roles[`role{Index}`] = string.rep("x", CONFIG_ROLE_BYTES)
	end
	Servers[1]:Seed("config", { Gold = START, Touches = 0, Roles = Roles })
	local Bytes = Measure(Servers[1]:Record("config"))

	local Before = Calls(Servers)
	local Bodies: { () -> () } = {}
	for _, Held in Servers do
		table.insert(Bodies, function()
			Held.Store:Peek("config"):Wait()
		end)
	end
	T:Race(Bodies)
	local Boot = Calls(Servers) - Before

	Before = Calls(Servers)
	local Ticks = MINUTES * (Windows.SWEEP // Windows.AUTOSAVE)
	for _ = 1, Ticks do
		for _, Held in Servers do
			Held.Store:Peek("config"):Wait()
		end
		T:Advance(Windows.AUTOSAVE)
	end
	local Polled = Calls(Servers) - Before

	local Lane = Datastore.READ_BYTES
	local PerMinute = Polled / MINUTES
	Row("every server reading one key at boot", Boot, 0, string.format("%.1f reads per server, %.1f MB on one key", Boot / SERVERS, Boot * Bytes / 1048576))
	Row(
		`and every {Windows.AUTOSAVE}s for {MINUTES} minutes`,
		Polled,
		0,
		string.format(
			"%d reads and %.1f MB a minute on one key of %d bytes, lane %d MB, %s",
			PerMinute,
			PerMinute * Bytes / 1048576,
			Bytes,
			Lane / 1048576,
			if PerMinute * Bytes > Lane then "OVER" else "inside"
		)
	)

	local Maps = Taken(T)
	Before = Calls(Servers)
	local Units = T.Service.Units
	Bodies = {}
	for _, Held in Servers do
		table.insert(Bodies, function()
			Held.Store:Peek("config", Windows.AUTOSAVE):Wait()
		end)
	end
	T:Race(Bodies)
	local CopiedBoot, BootUnits = Calls(Servers) - Before, T.Service.Units - Units

	Before, Units = Calls(Servers), T.Service.Units
	for _ = 1, Ticks do
		for _, Held in Servers do
			Held.Store:Peek("config", Windows.AUTOSAVE):Wait()
		end
		T:Advance(Windows.AUTOSAVE)
	end
	local CopiedPolled, PolledUnits = Calls(Servers) - Before, T.Service.Units - Units

	Row("every server reading a copy of that key at boot", CopiedBoot, BootUnits, string.format("%.2f reads per server", CopiedBoot / SERVERS))
	Row(
		`and every {Windows.AUTOSAVE}s for {MINUTES} minutes`,
		CopiedPolled,
		PolledUnits,
		string.format("%.1f reads and %.1f units per server per minute", CopiedPolled / SERVERS / MINUTES, PolledUnits / SERVERS / MINUTES)
	)
	Ceilings(T, Maps, MINUTES)
end)

Bench("mixed", function(T: Suite.Case)
	if SERVERS < 2 then
		print("  a mixed fleet needs more than one server, so this row is left out")
		return
	end

	local Stores: { any } = {}
	for Index = 1, SERVERS do
		Stores[Index] = Bare(T, Index, "Mixed", Index % 2 == 0)
	end
	local Old, New = Stores[1], Stores[2]

	local function Spent(): number
		local Total = 0
		for _, Held in Stores do
			Total += Held.Wrapper.Spent + Held.TxWrapper.Spent
		end
		return Total
	end

	Old:Edit("mixA", "Fund", { Amount = START }):Wait()
	Old:Edit("mixB", "Fund", { Amount = 0 }):Wait()
	local Listed = T.Hook.Fail(Fault.On("ListKeysAsync"):OnStore("Mixed_Tx"):Only(999))

	local Before, Units = Spent(), T.Service.Units
	local Wins = 0
	local Bodies: { () -> () } = {}
	for Index = 1, CONTENDERS do
		local Held = Stores[Index]
		table.insert(Bodies, function()
			local Ok = Held:Tx(`mix{Index}`, {
				{ Key = "mixA", Kind = "Give", Fields = { Amount = -1 } },
				{ Key = "mixB", Kind = "Give", Fields = { Amount = 1 } },
			}):Wait()
			if Ok then
				Wins += 1
			end
		end)
	end
	T:Race(Bodies)
	T:Advance(Windows.REAP + Windows.TX)
	for _, Held in Stores do
		Held:ReapMarkers()
	end
	for _, Held in { Old, New } do
		Held:Bump("pot", "Gold", 1):Wait()
	end
	for _, Held in Stores do
		Held:Total("pot", "Gold"):Wait()
	end
	for _, Held in { Old, New } do
		Held:Resettle("mixA"):Wait()
		Held:Resettle("mixB"):Wait()
	end

	local A = (Old:Peek("mixA"):Wait() :: any).Gold
	local B = (New:Peek("mixB"):Wait() :: any).Gold
	Row(
		"half the fleet without a cache, contending, reaping and totalling",
		Spent() - Before,
		T.Service.Units - Units,
		string.format("%d of %d contenders through, %d lists", Wins, CONTENDERS, Listed.Count)
	)
	print(`    money: {A} + {B} = {A + B}, started at {START}, {if A + B == START then "whole" else "WRONG"}, receiver holds {B} against {Wins} yes`)
	print(`    totals: old server {Old:Total("pot", "Gold"):Wait()}, new server {New:Total("pot", "Gold"):Wait()}`)
end)
