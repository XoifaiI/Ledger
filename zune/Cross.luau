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
	yes was then lost. Ledger did not accuse itself.

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
local Shards = require("../src/Core/Constants/Shards")
local Transactions = require("../src/Core/Constants/Transactions")

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
