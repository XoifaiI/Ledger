--!strict
--!optimize 2

--[=[
	Runner: Runs the V2 checks and prints the verdict.

	Two things live here. The cases are one rule each and take seconds. The sweep is the seeded
	fuzzer, the replay gate and the exhaustive walk, and it takes minutes. CASES and SWEEP turn each
	one on, and the cases finish before the sweep starts so neither reads the other's warnings.
	Put a failing seed into SEEDS and only that seed runs, in seconds.

	Return type: Nothing. It prints.
	Example usage:
		Press play. Set SWEEP to false to keep only the cases.
--]=]

local LogService = game:GetService("LogService")
local ServerStorage = game:GetService("ServerStorage")

local Root = ServerStorage:WaitForChild("LedgerDev"):WaitForChild("SimulationV2")
local Simulator = require(Root:WaitForChild("Simulator")) :: any
local Catalogue = require(Root:WaitForChild("Catalogue")) :: any
local Marks = require(Root:WaitForChild("Marks")) :: any
local Fleet = require(Root:WaitForChild("Actor"):WaitForChild("Fleet")) :: any
local Replay = require(Root:WaitForChild("Replay")) :: any
local Prove = require(Root:WaitForChild("Prove")) :: any
local Suite = require(Root:WaitForChild("Suite")) :: any

local CASES = true
local SWEEP = true

local MATCH = ""

local FROM = 1
local TO = 1000

local SEEDS: { number } = {}

local TRACE = false

local PARALLEL = true
local WORKERS = 8

local MISDIRECT = false

local SELF_ACCUSED = "this is a bug in Ledger"

local DRAIN_FRAMES = 8

local function Row(Title: string, Count: number)
	print(`  {Title} {string.rep(".", math.max(1, 34 - #Title))} {if Count == 0 then "none" else tostring(Count)}`)
end

local function Some(Title: string, Held: { string }, Most: number)
	if #Held == 0 then
		return
	end

	print(`\n  {Title}:`)
	for Index, Line in Held do
		if Index > Most then
			print(`    and {#Held - Most} more`)
			break
		end
		print(`    {Line}`)
	end
end

local CaseSheet: any = nil

if CASES then
	local Files: { any } = {}
	for _, Child in Root:WaitForChild("Cases"):GetChildren() do
		if Child:IsA("ModuleScript") then
			table.insert(Files, require(Child) :: any)
		end
	end
	table.sort(Files, function(Left: any, Right: any): boolean
		return Left.Name < Right.Name
	end)

	local Counted = 0
	for _, File in Files do
		Counted += #File.Cases
	end

	local Out = Suite.Run(Files, { Match = MATCH })
	CaseSheet = Out.Sheet

	local Says: { string } = {}
	for _, Held in Out.Broken do
		table.insert(Says, `{Held.File}: {Held.Name}: {Held.Says}`)
	end

	print("\n~~~~~~~~~~~~ SimulationV2 cases ~~~~~~~~~~~~")
	print(`  {Out.Ran} of {Counted} case(s) in {#Files} file(s), {string.format("%.2f", Out.Seconds)}s`)
	if MATCH ~= "" then
		print(`  filtered on '{MATCH}', {Out.Skipped} case(s) were not run`)
	end
	print("")
	print(`  marks       {Out.Sheet:Report()}`)
	print(`  warnings    {Out.Warnings} total`)
	print("")
	Row("cases failed", Out.Failed)
	Row("checks broken", #Out.Broken)
	Row("Ledger accused itself", #Out.Accused)

	Some("Ledger accused itself", Out.Accused, 5)
	Some("broken", Says, 40)

	if not Out.Ok then
		warn("~~~~~~~~~~~~ CASES FAILED ~~~~~~~~~~~~")
	else
		print("~~~~~~~~~~~~ CASES PASSED ~~~~~~~~~~~~")
	end

	if #Out.Slowest > 0 then
		print("\n  slowest case(s):")
		for _, Timed in Out.Slowest do
			print(`    {string.format("%6.1f", Timed.Seconds * 1000)}ms  {Timed.Name}`)
		end
	end
end

if not SWEEP then
	return
end

for _ = 1, DRAIN_FRAMES do
	task.wait()
end

local Sheet = Marks.New()
local Warnings = 0
local Accused: { string } = {}
local Tap = LogService.MessageOut:Connect(function(Message: string, Kind: Enum.MessageType)
	if Kind ~= Enum.MessageType.MessageWarning then
		return
	end

	Warnings += 1
	Sheet:Note(Message)
	if string.find(Message, SELF_ACCUSED, 1, true) ~= nil then
		table.insert(Accused, Message)
	end
end)

local Ahead: { string } = {}

local Repeats: { number } = { FROM, FROM + (TO - FROM) // 2, TO }
local Same = { Ok = true }
for _, Seed in Repeats do
	local Held = Replay.Check(Seed)
	if not Held.Ok then
		Same.Ok = false
		table.insert(Ahead, Held.Says)
	end
end

local Walked = Prove.Run()
for _, Line in Walked.Broken do
	table.insert(Ahead, `exhaustive: {Line}`)
end

local Started = os.clock()
local Cover = nil :: any
local Threw: { string } = {}
local Broken: { string } = {}
local Moved: { string } = {}
local Reached: { [string]: number } = {}
local Calls, Injected, Lost, Checked, Outside, Steps, Issued, Crashes = 0, 0, 0, 0, 0, 0, 0, 0

if PARALLEL and #SEEDS == 0 then
	local Out = Fleet.Sweep(FROM, TO, WORKERS, MISDIRECT, TRACE)
	Calls, Injected, Lost = Out.Calls, Out.Injected, Out.Lost
	Checked, Outside, Issued = Out.Checked, Out.Outside, Out.Issued
	Crashes = Out.Crashes
	Reached = Out.Reached
	Threw = Out.Threw
	Broken = Out.Broken
else
	local Wanted: { number } = SEEDS
	if #Wanted == 0 then
		Wanted = {}
		for Seed = FROM, TO do
			table.insert(Wanted, Seed)
		end
	end

	for _, Seed in Wanted do
		local Out = Simulator.Run(Seed, { Misdirect = MISDIRECT, Trace = TRACE })

		if Cover == nil then
			Cover = Out.Cover
		else
			Cover:Merge(Out.Cover)
		end

		Calls += Out.Calls
		Injected += Out.Injected
		Lost += Out.Lost
		Steps += Out.Steps
		Issued += Out.Issued
		Checked += Out.Books.Checked
		Outside += #Out.Books.Broken
		Crashes += Out.Crashes

		for _, Line in Out.Threw do
			table.insert(Threw, `seed {Seed}: {Line}`)
		end
		for _, Line in Out.Broken do
			table.insert(Broken, `seed {Seed}: {Line}`)
		end
		for _, Line in Out.Moved do
			table.insert(Moved, `seed {Seed}: {Line}`)
		end
	end
	for Bucket, Count in Cover.Counts do
		Reached[Bucket] = Count
	end
end

Tap:Disconnect()

local Missed: { string } = {}
local Silent: { string } = {}
local Starved: { string } = if Cover ~= nil then Cover:Starved() else {}
local Held = 0

for _, Bucket in Catalogue.Buckets() do
	if (Reached[Bucket] or 0) > 0 then
		Held += 1
	else
		table.insert(Missed, Bucket)
	end
end
table.sort(Missed)

for _, Operation in Catalogue.CATALOGUE do
	local Any = false
	for Bucket, Count in Reached do
		if Count > 0 and string.sub(Bucket, 1, #Operation.Name + 1) == `{Operation.Name}:` then
			Any = true
			break
		end
	end
	if not Any then
		table.insert(Silent, Operation.Name)
	end
end
table.sort(Silent)
local Unmarked = Sheet:Missed()

print("\n~~~~~~~~~~~~ SimulationV2 sweep ~~~~~~~~~~~~")
local Which = if #SEEDS > 0 then `seeds {table.concat(SEEDS, ", ")}` else `seeds {FROM} to {TO}`
print(`  {Which}, {string.format("%.1f", os.clock() - Started)}s, {if PARALLEL and #SEEDS == 0 then `{WORKERS} actors` else "serial"}`)
print(`  catalogue {#Catalogue.CATALOGUE} operations, {#Catalogue.Buckets()} outcomes`)
print("")
print(`  replay      seeds {table.concat(Repeats, ", ")} twice each, {if Same.Ok then "identical" else "DIFFERENT"}`)
print(`  exhaustive  {Walked.Walked} sequence(s) walked whole in {string.format("%.1f", Walked.Seconds)}s`)
print(`  coverage    {Held}/{#Catalogue.Buckets()} outcomes reached, {#Catalogue.CATALOGUE - #Silent}/{#Catalogue.CATALOGUE} operations issued`)
print(`  marks       {Sheet:Report()}`)
print(`  workload    {Issued} operation(s) issued`)
print(`  faults      {Calls} calls, {Injected} injected, {Lost} silent write(s)`)
print(`  crashes     {Crashes} server(s) stopped and rebuilt from the log`)
print(`  auditor     {Checked} answer(s) checked`)
print(`  warnings    {Warnings} total`)
print("")
Row("replay or exhaustive broken", #Ahead)
Row("threw", #Threw)
Row("books or liveness broken", #Broken)
Row("answered something not allowed", Outside)
Row("Ledger accused itself", #Accused)
Row("starved", #Starved)
Row("never issued", #Silent)
Row("outcomes not reached", #Missed)
Row("marks not reached", #Unmarked)

Some("replay or exhaustive broken", Ahead, 8)
Some("Ledger accused itself", Accused, 5)
Some("books or liveness broken", Broken, 70)
Some("writes that landed on the wrong key", Moved, 5)
Some("threw", Threw, 8)
Some("starved", Starved, 8)
Some("never issued", Silent, 8)
Some("marks not reached", Unmarked, 40)

if #Ahead > 0 or #Threw > 0 or #Broken > 0 or Outside > 0 or #Accused > 0 or #Starved > 0 or #Silent > 0 then
	warn("~~~~~~~~~~~~ SWEEP FAILED ~~~~~~~~~~~~")
else
	print("~~~~~~~~~~~~ SWEEP PASSED ~~~~~~~~~~~~")
	print(`  {#Missed} outcome(s) and {#Unmarked} mark(s) unreached, which is coverage left to win`)
end

-- the two halves reach different situations, so what they cover together is the number worth knowing
if CaseSheet ~= nil then
	Sheet:Merge(CaseSheet)
	print(`\n  cases and sweep together: {Sheet:Report()}`)
end
