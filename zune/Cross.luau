--!strict

--[=[

	Cross: Runs one operation inside every call another one makes, and checks the money after each.

	A case picks the interleavings a person thought of. This walks them. It counts the calls the
	driven operation makes, then runs the whole thing again once per call. Each run puts the crossing
	operation inside a different call. That operation runs on a second server, since a call from the
	driving server would queue behind the very call it is inside.

	It aims at the record store, the marker store and each MemoryStore map in turn. So a lease taken,
	evicted and retaken between two datastore calls is a schedule this reaches and a case does not.

	After every schedule it asks the same three things. The money is whole. Nothing Ledger answered
	yes was then lost. Ledger did not accuse itself. A schedule over a copied key asks two more. A
	copy never shows a state the record never held and never goes backwards. Once the map's items
	have run out, every server's copy is the fold of the record.

	Return type: Nothing. It prints, and sets the exit code.
	Example usage:
		zune run zune/Cross.luau
		zune run zune/Cross.luau "a transfer"
--]=]

local Engine = require("./Engine")

Engine.Install()

local Suite = require("../tests/Suite")
local Case = require("../tests/Suite/Case")
local Bookings = require("../src/Core/Constants/Bookings")
local Follows = require("../src/Core/Constants/Follows")
local Shards = require("../src/Core/Constants/Shards")
local Sizes = require("../src/Core/Constants/Sizes")
local Transactions = require("../src/Core/Constants/Transactions")
local Windows = require("../src/Core/Constants/Windows")

local Fault = Suite.Fault

Engine.Listen(Suite.Heard)

local MATCH = zune.process.args[2] or ""
local ACCUSED = "Ledger bug:"
local START = 100
local LIMIT = 64
local COUNTING = 1000000

type Fixture = Suite.Fixture
type Case = Suite.Case

type World = {
	Driver: Fixture,
	Crosser: Fixture,
	Seen: number?,
}

type Scenario = {
	Name: string,
	Aim: { string },
	Expect: number,
	Build: (T: Case) -> World,
	Drive: (T: Case, World: World) -> (),
	Cross: (T: Case, World: World) -> (),
	Whole: (T: Case, World: World) -> (number, string),
}

local METHODS = { "GetAsync", "UpdateAsync" }
local MODES: { string? } = { nil :: any, "failing", "partial" }

local Schedules = 0
local Crossed = 0
local Broke: { string } = {}

local function Note(Says: string)
	table.insert(Broke, Says)
end

local function Banks(T: Case): World
	local Driver, Crosser = T:Bank("nodeA"), T:Bank("nodeB")
	Driver:Seed("a", { Gold = START, Touches = 0 })
	Driver:Seed("b", { Gold = 0, Touches = 0 })
	return { Driver = Driver, Crosser = Crosser }
end

local function Money(T: Case, World: World): (number, string)
	local Driver = World.Driver
	local Total = Driver:Amount("a") + Driver:Amount("b") + Driver:Aside("a") + Driver:Aside("b")
	return Total, `{Driver:Amount("a")} + {Driver:Amount("b")} + {Driver:Aside("a") + Driver:Aside("b")} set aside`
end

local COPIED = "k"
local AGE = 30

local function Copied(T: Case): World
	local Driver, Crosser = T:Bank("nodeA"), T:Bank("nodeB")
	Driver:Seed(COPIED, { Gold = START, Touches = 0 })
	return { Driver = Driver, Crosser = Crosser }
end

local function Held(Held: Fixture): number?
	local Copy = Held.Store.Copies[COPIED]
	local State = if Copy ~= nil then Copy.State else nil
	return if type(State) == "table" then State.Gold else nil
end

local function Copies(T: Case, World: World): (number, string)
	local Truth = World.Driver:Amount(COPIED)
	local Servers = { World.Driver, World.Crosser }
	local Before: { number? } = {}
	for Index, Server in Servers do
		local Gold = Held(Server)
		Before[Index] = Gold
		if Gold ~= nil and (Gold < START or Gold > Truth) then
			T:Fail(`server {Index}'s copy`, `holds {Gold}, which the record never held between {START} and {Truth}`)
		end
	end
	local Seen = World.Seen
	local After = Held(World.Driver)
	if Seen ~= nil and After ~= nil and After < Seen then
		T:Fail("the driver's copy", `went backwards from {Seen} to {After}`)
	end

	T:Advance(AGE + 1)
	for Index, Server in Servers do
		Server.Store:Peek(COPIED, AGE):Wait()
		local Was, Now = Before[Index], Held(Server)
		if Was ~= nil and Now ~= nil and Now < Was then
			T:Fail(`server {Index}'s copy on its next read inside the window`, `went backwards from {Was} to {Now}`)
		end
	end

	T:Advance(Windows.TALLY_KEEP + 1)
	local Agreed = 0
	local Said: { string } = {}
	for _, Server in Servers do
		local Gold = Server.Store:Peek(COPIED, AGE):Wait()
		Gold = if type(Gold) == "table" then Gold.Gold else Gold
		table.insert(Said, tostring(Gold))
		if Gold == Truth then
			Agreed += 1
		end
	end
	return Agreed, `the record holds {Truth} and the copies answer {table.concat(Said, " and ")}`
end

local Scenarios: { Scenario } = {
	{
		Name = "a transfer crossed by a second transfer on the same keys",
		Aim = { "Data", "Lease", "Hold" },
		Expect = START,
		Build = Banks,
		Drive = function(_T: Case, World: World)
			World.Driver.Store:Transfer("a", "b", 30, "first"):Wait()
		end,
		Cross = function(_T: Case, World: World)
			World.Crosser.Store:Transfer("a", "b", 20, "second"):Wait()
		end,
		Whole = Money,
	},
	{
		Name = "a transfer crossed by a transaction on the same keys",
		Aim = { "Data", "Marked", "Lease" },
		Expect = START,
		Build = Banks,
		Drive = function(_T: Case, World: World)
			World.Driver.Store:Transfer("a", "b", 30, "moved"):Wait()
		end,
		Cross = function(_T: Case, World: World)
			World.Crosser.Store
				:Tx("crossed", {
					{ Key = "a", Kind = "Give", Fields = { Amount = -10 } },
					{ Key = "b", Kind = "Give", Fields = { Amount = 10 } },
				})
				:Wait()
		end,
		Whole = Money,
	},
	{
		Name = "a transaction crossed by a transfer on the same keys",
		Aim = { "Data", "Marked", "Lease" },
		Expect = START,
		Build = Banks,
		Drive = function(_T: Case, World: World)
			World.Driver.Store
				:Tx("driven", {
					{ Key = "a", Kind = "Give", Fields = { Amount = -30 } },
					{ Key = "b", Kind = "Give", Fields = { Amount = 30 } },
				})
				:Wait()
		end,
		Cross = function(_T: Case, World: World)
			World.Crosser.Store:Transfer("a", "b", 20, "beside"):Wait()
		end,
		Whole = Money,
	},
	{
		Name = "a transfer crossed by a resettle of the key it is leaving",
		Aim = { "Data", "Marked", "Lease" },
		Expect = START,
		Build = Banks,
		Drive = function(_T: Case, World: World)
			World.Driver.Store:Transfer("a", "b", 30, "resettled"):Wait()
		end,
		Cross = function(_T: Case, World: World)
			World.Crosser.Store:Resettle("a"):Wait()
		end,
		Whole = Money,
	},
	{
		Name = "a checkout crossed by a second buyer on one shelf",
		Aim = { "Data", "Hold" },
		Expect = 1,
		Build = function(T: Case): World
			local Driver, Crosser = T:Shelf("nodeA"), T:Shelf("nodeB")
			Driver:Seed("shelf", { Stock = 1, Sold = 0, Gold = 0 })
			return { Driver = Driver, Crosser = Crosser }
		end,
		Drive = function(_T: Case, World: World)
			if World.Driver.Store:Reserve("shelf", "Stock", 1, "mine"):Wait() then
				World.Driver.Store:Confirm("shelf", "mine", "Sell", { Count = 1 }):Wait()
			end
		end,
		Cross = function(_T: Case, World: World)
			if World.Crosser.Store:Reserve("shelf", "Stock", 1, "theirs"):Wait() then
				World.Crosser.Store:Confirm("shelf", "theirs", "Sell", { Count = 1 }):Wait()
			end
		end,
		Whole = function(_T: Case, World: World): (number, string)
			local State = World.Driver:State("shelf")
			return State.Stock + State.Sold, `{State.Stock} left and {State.Sold} sold`
		end,
	},
	{
		Name = "a cold copy crossed by an edit and a forced peek on the same key",
		Aim = { "Data", "Copy" },
		Expect = 2,
		Build = Copied,
		Drive = function(_T: Case, World: World)
			World.Driver.Store:Peek(COPIED, AGE):Wait()
		end,
		Cross = function(_T: Case, World: World)
			World.Crosser.Store:Edit(COPIED, "Fund", { Amount = 7 }):Wait()
			World.Crosser.Store:Peek(COPIED, 0):Wait()
		end,
		Whole = Copies,
	},
	{
		Name = "a stale copy's refill crossed by an edit and a forced peek",
		Aim = { "Data", "Copy" },
		Expect = 2,
		Build = function(T: Case): World
			local World = Copied(T)
			World.Driver.Store:Peek(COPIED, AGE):Wait()
			World.Crosser.Store:Peek(COPIED, AGE):Wait()
			T:Advance(Windows.TALLY_CACHE + Windows.COPY_SLACK + 1)
			return World
		end,
		Drive = function(_T: Case, World: World)
			World.Driver.Store:Peek(COPIED, AGE):Wait()
		end,
		Cross = function(_T: Case, World: World)
			World.Crosser.Store:Edit(COPIED, "Fund", { Amount = 7 }):Wait()
			World.Crosser.Store:Peek(COPIED, 0):Wait()
		end,
		Whole = Copies,
	},
	{
		Name = "an edit that compacts, crossed by a newer edit and the refill it makes, with the driver reading it between",
		Aim = { "Data", "Copy" },
		Expect = 2,
		Build = function(T: Case): World
			Sizes.Set({ Compact = 32 })
			local World = Copied(T)
			World.Driver.Store:Peek(COPIED, AGE):Wait()
			T:Advance(Windows.TALLY_CLAIM + 1)
			return World
		end,
		Drive = function(_T: Case, World: World)
			World.Driver.Store:Edit(COPIED, "Fund", { Amount = 7 }):Wait()
		end,
		Cross = function(_T: Case, World: World)
			World.Crosser.Store:Edit(COPIED, "Fund", { Amount = 11 }):Wait()
			World.Crosser.Store:Peek(COPIED, 0):Wait()
			World.Driver.Store:Peek(COPIED, 0):Wait()
			World.Seen = Held(World.Driver)
		end,
		Whole = Copies,
	},
}

local function Named(Held: Fixture, Aim: string): string
	if Aim == "Data" then
		return Held.Data
	end
	if Aim == "Marked" then
		return Held.Marked
	end
	if Aim == "Lease" then
		return Transactions.LEASE_MAP
	end
	if Aim == "Hold" then
		return Bookings.MAP
	end
	if Aim == "Copy" then
		return Follows.MAP
	end
	return Shards.MAP
end

local function Ran(Held: Scenario, Aim: string, Method: string, Mode: string?, At: number?): (number, string?)
	local Counted = 0
	local Says: string? = nil

	Suite.Cache(Mode :: any)
	local T = Case.Open("cross")
	local Raised = Case.Drive(T, function(T: Case)
		local World = Held.Build(T)
		local Watch = World.Driver.Hook.Fail(Fault.On(Method):OnStore(Named(World.Driver, Aim)):Only(At or COUNTING):Meddle(function()
			Held.Cross(T, World)
		end))

		Held.Drive(T, World)
		Counted = Watch.Count

		local Total, Reads = Held.Whole(T, World)
		if Total ~= Held.Expect then
			Says = `it holds {Total} against the {Held.Expect} it started with, {Reads}`
		end
	end)

	if Raised ~= nil then
		Says = Says or `the schedule threw: {Raised}`
	end
	for _, Held in T.Broken do
		Says = Says or Held
	end
	for _, Record in T.Records do
		if string.find(Record.Says, ACCUSED, 1, true) ~= nil then
			Says = Says or `Ledger accused itself: {Record.Says}`
		end
	end
	Case.Close(T)
	for _, Line in Case.Invariants(T) do
		Says = Says or `an invariant broke: {Line}`
	end
	return Counted, Says
end

print(`\n~~~~~~~~~~~~ Ledger crossings ~~~~~~~~~~~~`)

for _, Held in Scenarios do
	if MATCH ~= "" and string.find(Held.Name, MATCH, 1, true) == nil then
		continue
	end

	local Reached = 0
	for Index = 1, #MODES + 1 do
		local Mode = MODES[Index]
		local Says = if Mode == nil then "a map that answers" else `a map that is {Mode}`

		for _, Aim in Held.Aim do
			for _, Method in METHODS do
				local Calls, Wrong = Ran(Held, Aim, Method, Mode, nil)
				if Wrong ~= nil then
					Note(`{Held.Name}, {Aim} {Method} on {Says}, with nothing crossing it: {Wrong}`)
				end

				local Points = math.min(Calls, LIMIT)
				for At = 1, Points do
					Schedules += 1
					local _, Broke = Ran(Held, Aim, Method, Mode, At)
					if Broke ~= nil then
						Note(`{Held.Name}, inside {Method} {At} of {Calls} on {Aim}, {Says}: {Broke}`)
					end
				end
				Reached += Points
			end
		end
	end

	Crossed += 1
	print(string.format("  %-62s %4d schedule(s)", Held.Name, Reached))
end

print("")
print(`  {Crossed} scenario(s), {Schedules} schedule(s) walked`)
print("")

if #Broke == 0 then
	print("~~~~~~~~~~~~ EVERY SCHEDULE HELD ~~~~~~~~~~~~")
	return
end

for Index, Says in Broke do
	if Index > 20 then
		print(`    and {#Broke - 20} more`)
		break
	end
	print(`    {Says}`)
end

print("")
print(`~~~~~~~~~~~~ {#Broke} SCHEDULE(S) BROKE ~~~~~~~~~~~~`)
zune.process.exit(1)
