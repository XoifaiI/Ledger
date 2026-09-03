--!strict

--[=[

	Long: Runs one store across months of virtual time and checks nothing grows with the age of a key.

	Every window Ledger keeps something for is shorter than the run. A set bounded by a window has to
	come back to where it started, and a set bounded by a count has to stop climbing.

	It drives real traffic at a real cadence on the virtual clock. A month costs what the work costs
	rather than what the wait asks for. It prints what each set held at the end of every month.

	Return type: Nothing. It prints, and sets the exit code.
	Example usage:
		zune run zune/Long.luau
		zune run zune/Long.luau 6
--]=]

local Engine = require("./Engine")

Engine.Install()

local Suite = require("../tests/Suite")
local Case = require("../tests/Suite/Case")
local Compact = require("../src/Record/Compact")
local TableUtil = require("../src/Util/TableUtil")
local Windows = require("../src/Core/Constants/Windows")

Engine.Listen(Suite.Heard)

local MONTHS = tonumber(zune.process.args[2]) or 3
local DAY = Windows.DAY
local TRADES_A_DAY = 24
local ONCE_A_DAY = 12
local ACCUSED = "Ledger bug:"
local START = 1000000
local SLACK = 1.2

type Fixture = Suite.Fixture

local Broke: { string } = {}

local function Note(Says: string)
	table.insert(Broke, Says)
	print(`  WRONG: {Says}`)
end

local function Count(Held: any): number
	return TableUtil.Count(Held)
end

local function Held(Bank: Fixture, Key: string): number
	local State = Bank:State(Key)
	local Aside = 0
	for _, Entry in State._Held or {} do
		if type(Entry) == "table" and type(Entry.Amount) == "number" then
			Aside += Entry.Amount
		end
	end
	return State.Gold + Aside
end

print(`\n~~~~~~~~~~~~ Ledger over {MONTHS} month(s) of virtual time ~~~~~~~~~~~~`)

local T = Case.Open("long")
local Raised = Case.Drive(T, function(T: Suite.Case)
	local Bank = T:Bank("nodeA")
	local Beside = T:Bank("nodeB")
	Bank:Seed("a", { Gold = START, Touches = 0 })
	Bank:Seed("b", { Gold = 0, Touches = 0 })

	local Day = 0
	local Sent, Landed, Named = 0, 0, 0
	local Settled = 0
	local Window = (Windows.PRUNE // DAY) * (TRADES_A_DAY * 2 + ONCE_A_DAY)

	for Month = 1, MONTHS do
		for _ = 1, 30 do
			Day += 1
			for Trade = 1, TRADES_A_DAY do
				Sent += 1
				if Bank.Store:Transfer("a", "b", 1, `day{Day}t{Trade}`):Wait() then
					Landed += 1
				end
				T:Advance(DAY // (TRADES_A_DAY + ONCE_A_DAY))
			end

			for Once = 1, ONCE_A_DAY do
				Named += 1
				Bank.Store:Edit("a", "Fund", { Amount = 0, Once = `day{Day}n{Once}` }):Wait()
				T:Advance(DAY // (TRADES_A_DAY + ONCE_A_DAY))
			end

			if Day % 2 == 0 then
				Beside.Store
					:Tx(`tx{Day}`, {
						{ Key = "a", Kind = "Give", Fields = { Amount = -1 } },
						{ Key = "b", Kind = "Give", Fields = { Amount = 1 } },
					})
					:Wait()
			end
			T:Sweep()
		end

		local Money = Held(Bank, "a") + Held(Bank, "b")
		local Names = Count(Bank:Names("a")) + Count(Bank:Names("b"))
		local Record = Bank:Record("a")
		local Marks = #Bank:Marks()

		print(
			string.format(
				"  month %d: money %d, applied names %d, ops on the busiest key %d, seen %d, markers %d, state %d bytes",
				Month,
				Money,
				Names,
				#Record.Ops,
				#Record.Seen,
				Marks,
				Compact.Bulk(Record)
			)
		)

		if Money ~= START then
			Note(`money is {Money} against {START} it started with, after month {Month}`)
		end
		if #Record.Seen > Compact.SEEN_LIMIT then
			Note(`the seen set on 'a' holds {#Record.Seen}, past its cap of {Compact.SEEN_LIMIT}, after month {Month}`)
		end

		if Month == 1 then
			Settled = Names
			continue
		end
		if Names > Settled * SLACK then
			Note(`applied names hold {Names} after month {Month} against {Settled} after the first, so they grow with the age of the key`)
		end
	end

	local Names = Count(Bank:Names("a")) + Count(Bank:Names("b"))
	print(`  wrote {Sent} transfers and {Named} named ops over {MONTHS * 30} days, {Landed} transfers landed`)
	print(`  applied names held at the end: {Names}, against {Sent + Named} ever written and one window of about {Window}`)

	if Names >= Sent + Named and MONTHS > 1 then
		Note(`applied names hold {Names}, as many as were ever written, so nothing aged out at the prune window`)
	end
end)

if Raised ~= nil then
	Note(`the run threw: {Raised}`)
end
for _, Says in T.Broken do
	Note(Says)
end
for _, Record in T.Records do
	if string.find(Record.Says, ACCUSED, 1, true) ~= nil then
		Note(`Ledger accused itself: {Record.Says}`)
	end
end
Case.Close(T)

print("")
if #Broke == 0 then
	print("~~~~~~~~~~~~ NOTHING GREW WITH THE AGE OF A KEY ~~~~~~~~~~~~")
	return
end

print(`~~~~~~~~~~~~ {#Broke} PROBLEM(S) ~~~~~~~~~~~~`)
zune.process.exit(1)
