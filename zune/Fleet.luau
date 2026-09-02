--!strict

--[=[

	Fleet: Runs the MemoryStore features against a fleet of servers on the mock and prints the cost.

	N servers over one datastore and one MemoryStore, driven at their real cadence on the virtual
	clock: every server reaps once per ten minutes, sweeps once a minute, draws a pot every five
	seconds, and thirty two of them contend on one bank key. It prints datastore calls and MemoryStore
	units for each, with the cache as it is or absent, so the before and after are measured and not
	worked out.

	Return type: Nothing. It prints.
	Example usage:
		zune run zune/Fleet.luau 5000
		zune run zune/Fleet.luau 5000 absent
--]=]

local Engine = require("./Engine")

Engine.Install()

local Suite = require("../tests/Suite")
local Case = require("../tests/Suite/Case")
local Ledger = require("../src") :: any
local Wrapper = require("../src/Util/DataStoreWrapper")
local Sessions = require("../src/Core/Constants/Sessions")
local Shards = require("../src/Core/Constants/Shards")
local Sweeper = require("../src/Store/Sweeper")
local Transactions = require("../src/Core/Constants/Transactions")
local Windows = require("../src/Core/Constants/Windows")

local Fault = Suite.Fault

Engine.Listen(Suite.Heard)

local SERVERS = tonumber(zune.process.args[2]) or 1000
local MODE = zune.process.args[3]
local MINUTES = 10
local HOUR = 60
local CONTENDERS = 32
local POT_TICK = 5
local START = 100
local CHAOS_SERVERS = 200
local CHAOS_DROP = 0.03
local CHAOS_STALL = 0.02
local CHAOS_TX = 3
local IDLE_MINUTES = 10
local IDLE_WRITES = 200
local ACCUSED = "Ledger bug:"

type Fixture = Suite.Fixture

Suite.Cache(MODE :: any)

local function Row(Label: string, Calls: number, Units: number, Per: string)
	print(string.format("  %-58s %10d calls %10d units   %s", Label, Calls, Units, Per))
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
		for _, Name in { Held.Data, Held.Marked, Transactions.LEASE_MAP, Shards.MAP, Sessions.FLAG_MAP } do
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
	local Batch = math.ceil(SERVERS / MINUTES)
	for Minute = 1, MINUTES do
		for Index = (Minute - 1) * Batch + 1, math.min(Minute * Batch, SERVERS) do
			Servers[Index].Store:ReapMarkers()
		end
		T:Advance(Windows.SWEEP)
	end

	local Spent = Calls(Servers) - Before
	Row(`reaping, every server once over {MINUTES} minutes`, Spent, T.Service.Units - Units, string.format("%.1f calls per server", Spent / SERVERS))
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
	T:Wait(Windows.IDLE_FALLBACK + Windows.AUTOSAVE * 2)

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
end)

Bench("mixed", function(T: Suite.Case)
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
