--!strict
--!optimize 2

--[=[
	Runner: Runs the cases and prints the verdict.

	One rule to a case. MATCH runs only the cases whose name holds it, which is how you work on one.
	A case that fails says which check and what it wanted, and a case that reaches a warning nothing
	expected fails too, because a message Ledger prints in a case that did not ask for it is either a
	bug or a case that has drifted.

	Return type: Nothing. It prints.
	Example usage:
		Press play. Put a fragment in MATCH to run one case.
--]=]

local ServerStorage = game:GetService("ServerStorage")

local Dev = ServerStorage:WaitForChild("LedgerDev")
local Root = Dev:WaitForChild("tests")

local Say = require(Dev:WaitForChild("src"):WaitForChild("Util"):WaitForChild("Tools"):WaitForChild("Say")) :: any
local Suite = require(Root:WaitForChild("Suite")) :: any

local MATCH = ""
local QUIET = true

local SHOW_BROKEN = 40
local SHOW_ACCUSED = 20

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

print("\n~~~~~~~~~~~~ Ledger cases ~~~~~~~~~~~~")
print(`  {Out.Ran} of {Counted} case(s) in {#Files} file(s), {string.format("%.2f", Out.Seconds)}s`)
print("")
print(`  warnings    {Out.Warnings} total`)
print("")

Row("cases failed", Out.Failed)
Row("checks broken", #Out.Broken)
Row("Ledger accused itself", #Out.Accused)

local Broken: { string } = {}
for _, Held in Out.Broken do
	table.insert(Broken, `{Held.Name}: {Held.Says}`)
end

Some("broken", Broken, SHOW_BROKEN)
Some("Ledger accused itself", Out.Accused, SHOW_ACCUSED)

print("")
if Out.Failed == 0 and #Out.Broken == 0 and #Out.Accused == 0 then
	print("~~~~~~~~~~~~ CASES PASSED ~~~~~~~~~~~~")
	return
end
warn("~~~~~~~~~~~~ CASES FAILED ~~~~~~~~~~~~")
