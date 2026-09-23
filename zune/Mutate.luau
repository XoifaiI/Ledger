--!strict

--[=[

	Mutate: Breaks src one line at a time and says which breaks the suite never notices.

	Each mutant is one change a real bug has made before. A guard that never fires, a comparison made
	strict or loose, a generation check turned round, a call that never happens, and an answer
	swapped for another. Each runs the whole suite in a copy of the tree of its own. A mutant that
	stays green is logic no case holds. The fake datastore, the virtual scheduler and the type files
	are left alone, since breaking them tests the harness rather than Ledger.

	A mutant that runs past the limit counts as hung, and one that cannot even load counts as
	invalid. Neither is a finding. The survivors are written beside the copies as well as printed.

	Return type: Nothing. It prints, and sets the exit code.
	Example usage:
		zune run zune/Mutate.luau
		zune run zune/Mutate.luau 12 Protocol/Tx guard
		zune run zune/Mutate.luau 1 "" "" count
--]=]

local WORKERS = tonumber(zune.process.args[2]) or 12
local MATCH = zune.process.args[3] or ""
local ONLY = zune.process.args[4] or ""
local COUNTING = zune.process.args[5] == "count"

local LIMIT = 180
local TIMEOUT = "C:/Program Files/Git/usr/bin/timeout.exe"
local ZUNE = zune.fs.getExePath()
local BASE = `{zune.process.env.TEMP}/ledger-mutants`
local COPIED = { "src", "tests", "zune", ".luaurc" }

local SKIPPED = { "src/Mock/", "src/Schedulers/Virtual", "src/Hooks/Memory", "src/Core/Constants/", "src/Core/Api", "src/Core/TypeFunctions", "Types.luau" }
local QUIET = { warn = true, print = true, assert = true, ["table.freeze"] = true }
local COMPARED = { " <= ", " >= ", " < ", " > " }
local FLIPPED: { [string]: string } = { [" <= "] = " < ", [" >= "] = " > ", [" < "] = " <= ", [" > "] = " >= " }
local EQUALS = { " == ", " ~= " }
local OPPOSED: { [string]: string } = { [" == "] = " ~= ", [" ~= "] = " == " }
local ANSWERS: { [string]: string } = {
	BUSY = "UNRESOLVED",
	UNRESOLVED = "BUSY",
	SPENT = "REFUSED",
	REFUSED = "SPENT",
	HELD = "BUSY",
	FULL = "BUSY",
	BEHIND = "REFUSED",
	INVALID = "REFUSED",
	CLOSED = "UNRESOLVED",
	BACKLOG = "BUSY",
	Busy = "Unresolved",
	Unresolved = "Busy",
	Spent = "Refused",
	Refused = "Spent",
	Held = "Busy",
	Full = "Busy",
	Behind = "Refused",
}

type Mutant = {
	File: string,
	Line: number,
	Kind: string,
	Before: string,
	After: string,
}

local function Files(Folder: string, Into: { string })
	for _, Entry in zune.fs.entries(Folder) do
		local Path = `{Folder}/{Entry.name}`
		if Entry.kind == "directory" then
			Files(Path, Into)
		elseif string.sub(Entry.name, -5) == ".luau" then
			table.insert(Into, Path)
		end
	end
end

local function Skipped(Path: string): boolean
	for _, Part in SKIPPED do
		if string.find(Path, Part, 1, true) ~= nil then
			return true
		end
	end
	return MATCH ~= "" and string.find(Path, MATCH, 1, true) == nil
end

local function Lines(Text: string): { string }
	local Out: { string } = {}
	for Line in string.gmatch(Text .. "\n", "(.-)\r?\n") do
		table.insert(Out, Line)
	end
	return Out
end

local function Every(Line: string, Token: string): { number }
	local Found: { number } = {}
	local From = 1
	while true do
		local At = string.find(Line, Token, From, true)
		if At == nil then
			return Found
		end
		table.insert(Found, At)
		From = At + #Token
	end
end

local function Swapped(Line: string, At: number, Token: string, With: string): string
	return string.sub(Line, 1, At - 1) .. With .. string.sub(Line, At + #Token)
end

local function Checked(Line: string): boolean
	local Trimmed = string.match(Line, "^%s*(.-)$") or ""
	return string.sub(Trimmed, 1, 7) == "assert(" or string.sub(Trimmed, 1, 2) == "--"
end

local function Guards(File: string, Text: { string }, Add: (Mutant) -> ())
	for Index, Line in Text do
		local Lead, Condition = string.match(Line, "^(%s*)if (.+) then$")
		local Next = Text[Index + 1]
		if Lead == nil or Condition == nil or Next == nil then
			continue
		end
		local Exit = string.match(Next, "^%s*(%a+)")
		if Exit == "return" or Exit == "continue" or Exit == "break" then
			Add({ File = File, Line = Index, Kind = "guard", Before = Line, After = `{Lead}if false then` })
		end
	end
end

local function Boundaries(File: string, Text: { string }, Add: (Mutant) -> ())
	for Index, Line in Text do
		if Checked(Line) then
			continue
		end
		for _, Token in COMPARED do
			for _, At in Every(Line, Token) do
				Add({ File = File, Line = Index, Kind = "boundary", Before = Line, After = Swapped(Line, At, Token, FLIPPED[Token]) })
			end
		end
	end
end

local function Generations(File: string, Text: { string }, Add: (Mutant) -> ())
	for Index, Line in Text do
		if Checked(Line) or string.find(Line, "Gen", 1, true) == nil then
			continue
		end
		for _, Token in EQUALS do
			for _, At in Every(Line, Token) do
				Add({ File = File, Line = Index, Kind = "generation", Before = Line, After = Swapped(Line, At, Token, OPPOSED[Token]) })
			end
		end
	end
end

local function Calls(File: string, Text: { string }, Add: (Mutant) -> ())
	for Index, Line in Text do
		local Name = string.match(Line, "^%s*([%a_][%w_%.:]*)%b()$")
		if Name == nil or QUIET[Name] then
			continue
		end
		Add({ File = File, Line = Index, Kind = "call", Before = Line, After = "" })
	end
end

local function Answers(File: string, Text: { string }, Add: (Mutant) -> ())
	local Whole = table.concat(Text, "\n")
	for Index, Line in Text do
		if string.match(Line, "^%s*return ") == nil then
			continue
		end
		for Word, With in ANSWERS do
			local From = 1
			while true do
				local Start, Stop = string.find(Line, `%f[%w_]{Word}%f[^%w_]`, From)
				if Start == nil or Stop == nil then
					break
				end
				local Before = string.sub(Line, 1, Start - 1)
				local Qualified = string.sub(Before, -8) == "Reasons."
				local Defined = string.upper(Word) == Word and string.find(Whole, `local {With} =`, 1, true) ~= nil
				if Qualified or Defined then
					Add({ File = File, Line = Index, Kind = "answer", Before = Line, After = Before .. With .. string.sub(Line, Stop + 1) })
				end
				From = Stop + 1
			end
		end
	end
end

local KINDS: { [string]: (string, { string }, (Mutant) -> ()) -> () } = {
	guard = Guards,
	boundary = Boundaries,
	generation = Generations,
	call = Calls,
	answer = Answers,
}

local function Mutants(): { Mutant }
	local Paths: { string } = {}
	Files("src", Paths)
	table.sort(Paths)

	local Out: { Mutant } = {}
	for _, Path in Paths do
		if Skipped(Path) then
			continue
		end
		local Text = Lines(zune.fs.readFile(Path))
		for Kind, Make in KINDS do
			if ONLY ~= "" and Kind ~= ONLY then
				continue
			end
			Make(Path, Text, function(Held: Mutant)
				table.insert(Out, Held)
			end)
		end
	end
	table.sort(Out, function(Left: Mutant, Right: Mutant): boolean
		if Left.File ~= Right.File then
			return Left.File < Right.File
		end
		return Left.Line < Right.Line
	end)
	return Out
end

local function Run(Tree: string): string
	local Result = zune.process.run(TIMEOUT, { tostring(LIMIT), ZUNE, "run", "zune/Cases.luau" }, { cwd = Tree, stdout = "ignore", stderr = "ignore" })
	if Result.code == 124 then
		return "hung"
	end
	return if Result.code == 0 then "survived" else "killed"
end

local function Mutated(Held: Mutant, Original: string): string?
	local Text = Lines(Original)
	Text[Held.Line] = Held.After
	local Source = table.concat(Text, "\n")
	return if pcall(zune.luau.compile, Source) then Source else nil
end

local function Planted(Index: number): string
	local Tree = `{BASE}/w{Index}`
	pcall(zune.fs.deleteDir, Tree, true)
	zune.fs.makeDir(Tree, true)
	for _, Part in COPIED do
		zune.fs.copy(Part, `{Tree}/{Part}`)
	end
	return Tree
end

local Found = Mutants()
local Tally: { [string]: { [string]: number } } = {}
for Kind in KINDS do
	Tally[Kind] = { killed = 0, survived = 0, hung = 0, invalid = 0, made = 0 }
end
for _, Held in Found do
	Tally[Held.Kind].made += 1
end

print(`\n~~~~~~~~~~~~ Ledger mutants ~~~~~~~~~~~~`)
for Kind, Counts in Tally do
	print(`  {Kind} {string.rep(".", 12 - #Kind)} {Counts.made} made`)
end
print(`  {#Found} in all`)
if COUNTING or #Found == 0 then
	return
end

local Trees: { string } = {}
local Checked = 0
local Count = math.min(WORKERS, #Found)
for Index = 1, Count do
	local Tree = Planted(Index)
	Trees[Index] = Tree
	zune.task.spawn(function()
		local Clean = Run(Tree)
		assert(Clean == "survived", `the untouched copy at {Tree} did not pass, it came back {Clean}, so no mutant can be judged`)
		Checked += 1
	end)
end
while Checked < Count do
	zune.task.wait(0.5)
end

local Survivors: { Mutant } = {}
local Listed: { string } = {}
local Next = 0
local Done = 0
local Started = os.clock()

local function Said(Held: Mutant): string
	local Trimmed = string.match(Held.Before, "^%s*(.-)$") or Held.Before
	local Into = string.match(Held.After, "^%s*(.-)$") or Held.After
	return `{Held.File}:{Held.Line} [{Held.Kind}] {Trimmed}  ->  {if Into == "" then "(removed)" else Into}`
end

for _, Tree in Trees do
	zune.task.spawn(function()
		while true do
			Next += 1
			local Held = Found[Next]
			if Held == nil then
				return
			end

			local Path = `{Tree}/{Held.File}`
			local Original = zune.fs.readFile(Path)
			local Source = Mutated(Held, Original)
			local Verdict = "invalid"
			if Source ~= nil then
				zune.fs.writeFile(Path, Source)
				Verdict = Run(Tree)
				zune.fs.writeFile(Path, Original)
			end

			Tally[Held.Kind][Verdict] += 1
			if Verdict == "survived" then
				table.insert(Survivors, Held)
				table.insert(Listed, Said(Held))
				zune.fs.writeFile(`{BASE}/survivors.txt`, table.concat(Listed, "\n"))
			end
			Done += 1
			print(`  {Done}/{#Found} {Verdict} {Held.File}:{Held.Line} [{Held.Kind}], {#Survivors} survived, {math.floor(os.clock() - Started)}s`)
		end
	end)
end

while Done < #Found do
	zune.task.wait(0.5)
end

table.sort(Survivors, function(Left: Mutant, Right: Mutant): boolean
	if Left.File ~= Right.File then
		return Left.File < Right.File
	end
	return Left.Line < Right.Line
end)

local Report: { string } = {}
for _, Held in Survivors do
	table.insert(Report, Said(Held))
end
zune.fs.writeFile(`{BASE}/survivors.txt`, table.concat(Report, "\n"))

print("")
for Kind, Counts in Tally do
	print(`  {Kind} {string.rep(".", 12 - #Kind)} {Counts.killed} killed, {Counts.survived} survived, {Counts.hung} hung, {Counts.invalid} invalid`)
end
print(`\n  survivors, also in {BASE}/survivors.txt:`)
for _, Line in Report do
	print(`    {Line}`)
end
print(`\n  {math.floor(os.clock() - Started)}s`)
if #Survivors > 0 then
	zune.process.exit(1)
end
