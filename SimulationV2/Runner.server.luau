--!strict
--!optimize 2

--[=[
	Runner: Runs the V2 checks and prints the verdict.

	Two things live here. The cases are one rule each and take seconds. The sweep is the seeded
	fuzzer, the replay gate and the exhaustive walk, and it takes minutes. CASES and SWEEP turn each
	one on, and the cases finish before the sweep starts so neither reads the other's warnings.
	A sweep walks the indices FROM to TO. With RANDOM off and ENTROPY empty an index is the seed, so
	a run covers the same ground every time. RANDOM draws entropy from random.org as the run starts
	and turns each index into a seed spread over the whole space, so a run walks seeds nobody has
	walked. It prints what it drew, and putting that into ENTROPY walks the same seeds again.
	Put a failing seed into SEEDS and only that seed runs, in seconds.

	Return type: Nothing. It prints.
	Example usage:
		Press play. Set SWEEP to false to keep only the cases.
--]=]

local ServerStorage = game:GetService("ServerStorage")

local Dev = ServerStorage:WaitForChild("LedgerDev")
local Root = Dev:WaitForChild("SimulationV2")

local Simulator = require(Root:WaitForChild("Simulator")) :: any
local Say = require(Dev:WaitForChild("src"):WaitForChild("Util"):WaitForChild("Say")) :: any
local Catalogue = require(Root:WaitForChild("Catalogue")) :: any
local Marks = require(Root:WaitForChild("Marks")) :: any
local Seeds = require(Root:WaitForChild("Seeds")) :: any
local Fleet = require(Root:WaitForChild("Actor"):WaitForChild("Fleet")) :: any
local Replay = require(Root:WaitForChild("Replay")) :: any
local Prove = require(Root:WaitForChild("Prove")) :: any
local Suite = require(Root:WaitForChild("Suite")) :: any

local CASES = true
local SWEEP = true

local MATCH = ""

local FROM = 1
local TO = 100_000
local RANDOM = true
local ENTROPY = ""
local SEEDS: { number } = {}

local PARALLEL = true
local WORKERS = 32

local MISDIRECT = false
local TRACE = false
local QUIET = true

local SELF_ACCUSED = Marks.ACCUSED
local ACCUSED_KEPT = 50
local DRAIN_FRAMES = 8

local SHOW_AHEAD = 8
local SHOW_ACCUSED = 5
local SHOW_BROKEN = 70
local SHOW_MOVED = 5
local SHOW_THREW = 8
local SHOW_STARVED = 8
local SHOW_SILENT = 8
local SHOW_UNMARKED = 40

Say.Quiet(QUIET)

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

local function Seeded(): boolean
	return #SEEDS > 0
end

local function Drawn(): string
	if ENTROPY ~= "" or not RANDOM or Seeded() then
		return ENTROPY
	end

	local Held = Seeds.Fetch()
	print("")
	print(`  entropy    drew '{Held}' from random.org, put it in ENTROPY to walk these seeds again`)
	return Held
end

local function Wanted(Entropy: string): { number }
	if Seeded() then
		return SEEDS
	end
	return Seeds.Spread(Entropy, FROM, TO)
end

local function RunCases(): any
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

	Some("Ledger accused itself", Out.Accused, SHOW_ACCUSED)
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

	return Out.Sheet
end

local function RunSweep(CaseSheet: any)
	for _ = 1, DRAIN_FRAMES do
		task.wait()
	end

	local Sheet = Marks.New()
	local Warnings = 0
	local Accusations = 0
	local Accused: { string } = {}

	local function Fold(Said: { { Says: string, Count: number } })
		for _, Record in Said do
			Warnings += Record.Count
			Sheet:Note(Record.Says, Record.Count)
			if string.find(Record.Says, SELF_ACCUSED, 1, true) == nil then
				continue
			end

			Accusations += Record.Count
			if #Accused < ACCUSED_KEPT then
				table.insert(Accused, Record.Says)
			end
		end
	end

	local Entropy = Drawn()
	local Ahead: { string } = {}

	local Repeats: { number } = if Seeded()
		then { SEEDS[1], SEEDS[#SEEDS // 2 + 1], SEEDS[#SEEDS] }
		else { Seeds.At(Entropy, FROM), Seeds.At(Entropy, FROM + (TO - FROM) // 2), Seeds.At(Entropy, TO) }
	local Same = true
	for _, Seed in Repeats do
		local Held = Replay.Check(Seed)
		if not Held.Ok then
			Same = false
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
	local Calls, Injected, Lost, Checked, Outside, Issued, Crashes = 0, 0, 0, 0, 0, 0, 0

	local Flying = PARALLEL and not Seeded()
	if Flying then
		local Out = Fleet.Sweep(FROM, TO, WORKERS, MISDIRECT, TRACE, Entropy)
		Calls, Injected, Lost = Out.Calls, Out.Injected, Out.Lost
		Checked, Outside, Issued = Out.Checked, Out.Outside, Out.Issued
		Crashes = Out.Crashes
		Reached = Out.Reached
		Threw = Out.Threw
		Broken = Out.Broken

		Warnings += Out.Warnings
		Accusations += Out.Accusations
		Sheet:Merge({ Counts = Out.Counts, Unknown = Out.Unknown })
		for _, Line in Out.Accused do
			table.insert(Accused, Line)
		end
	else
		for _, Seed in Wanted(Entropy) do
			local Out = Simulator.Run(Seed, { Misdirect = MISDIRECT, Trace = TRACE })

			if Cover == nil then
				Cover = Out.Cover
			else
				Cover:Merge(Out.Cover)
			end

			Calls += Out.Calls
			Injected += Out.Injected
			Lost += Out.Lost
			Issued += Out.Issued
			Checked += Out.Books.Checked
			Outside += #Out.Books.Broken
			Crashes += Out.Crashes
			Fold(Out.Said)

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

	local Which = if Seeded()
		then `seeds {table.concat(SEEDS, ", ")}`
		elseif Entropy == "" then `seeds {FROM} to {TO}`
		else `{TO - FROM + 1} seed(s) drawn from entropy '{Entropy}', indices {FROM} to {TO}`

	print("\n~~~~~~~~~~~~ SimulationV2 sweep ~~~~~~~~~~~~")
	print(`  {Which}, {string.format("%.1f", os.clock() - Started)}s, {if Flying then `{WORKERS} actors` else "serial"}`)
	print(`  catalogue {#Catalogue.CATALOGUE} operations, {#Catalogue.Buckets()} outcomes`)
	print("")
	print(`  replay      seeds {table.concat(Repeats, ", ")} twice each, {if Same then "identical" else "DIFFERENT"}`)
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
	Row("Ledger accused itself", Accusations)
	Row("starved", #Starved)
	Row("never issued", #Silent)
	Row("outcomes not reached", #Missed)
	Row("marks not reached", #Unmarked)

	Some("replay or exhaustive broken", Ahead, SHOW_AHEAD)
	Some("Ledger accused itself", Accused, SHOW_ACCUSED)
	Some("books or liveness broken", Broken, SHOW_BROKEN)
	Some("writes that landed on the wrong key", Moved, SHOW_MOVED)
	Some("threw", Threw, SHOW_THREW)
	Some("starved", Starved, SHOW_STARVED)
	Some("never issued", Silent, SHOW_SILENT)
	Some("marks not reached", Unmarked, SHOW_UNMARKED)

	if #Ahead > 0 or #Threw > 0 or #Broken > 0 or Outside > 0 or Accusations > 0 or #Starved > 0 or #Silent > 0 then
		warn("~~~~~~~~~~~~ SWEEP FAILED ~~~~~~~~~~~~")
	else
		print("~~~~~~~~~~~~ SWEEP PASSED ~~~~~~~~~~~~")
		print(`  {#Missed} outcome(s) and {#Unmarked} mark(s) unreached, which is coverage left to win`)
	end

	if CaseSheet ~= nil then
		Sheet:Merge(CaseSheet)
		print(`\n  cases and sweep together: {Sheet:Report()}`)
	end
end

local CaseSheet: any = if CASES then RunCases() else nil
if SWEEP then
	RunSweep(CaseSheet)
end
