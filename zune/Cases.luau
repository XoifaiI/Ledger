--!strict

--[=[

	Cases: Runs the case suite outside Roblox and prints the verdict.

	It puts the Roblox vocabulary in place, points warn at the bench, loads every module under
	tests/Cases and runs them. A fragment after the file name runs only the cases whose name holds it,
	and a second word, absent, failing or partial, runs every bench with the MemoryStore in that state and
	leaves out the files that test the cache itself.

	Return type: Nothing. It prints, and sets the exit code.
	Example usage:
		zune run zune/Cases.luau
		zune run zune/Cases.luau "a transfer"
		zune run zune/Cases.luau "" failing
--]=]

local Engine = require("./Engine")

Engine.Install()

local Suite = require("../tests/Suite")

Engine.Listen(Suite.Heard)

local MATCH = zune.process.args[2] or ""
local CACHE = zune.process.args[3]
local SHOW_BROKEN = 40
local SHOW_ACCUSED = 20

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

local Named: { string } = {}
for _, Entry in zune.fs.entries("./tests/Cases") do
	local Held = Entry.name
	if string.sub(Held, -5) == ".luau" then
		table.insert(Named, string.sub(Held, 1, -6))
	end
end
table.sort(Named)

local Files: { any } = {}
for _, Held in Named do
	table.insert(Files, require(`../tests/Cases/{Held}`) :: any)
end

local Counted = 0
for _, File in Files do
	Counted += #File.Cases
end

if CACHE ~= nil then
	Suite.Cache(CACHE :: any)
end
local Out = Suite.Run(Files, { Match = MATCH, Skip = if CACHE ~= nil then { "cache" } else nil })

print(`\n~~~~~~~~~~~~ Ledger cases, on Zune{if CACHE ~= nil then `, MemoryStore {CACHE}` else ""} ~~~~~~~~~~~~`)
print(`  {Out.Ran} of {Counted} case(s) in {#Files} file(s), {string.format("%.2f", Out.Seconds)}s`)
print("")
print(`  warnings    {Out.Warnings} total`)
print("")

Row("cases failed", Out.Failed)
Row("checks broken", #Out.Broken)
Row("Ledger accused itself", #Out.Accused)

local Broken: { string } = {}
for _, Held in Out.Broken do
	table.insert(Broken, `{Held.File}: {Held.Name}: {Held.Says}`)
end

Some("broken", Broken, SHOW_BROKEN)
Some("Ledger accused itself", Out.Accused, SHOW_ACCUSED)

print("")
if Out.Ok then
	print("~~~~~~~~~~~~ CASES PASSED ~~~~~~~~~~~~")
	return
end

print("~~~~~~~~~~~~ CASES FAILED ~~~~~~~~~~~~")
zune.process.exit(1)
