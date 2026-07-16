--!strict

--[=[
    Tests: the chaos and property suite for Ledger, split per module and run through
    the Testing library.

    every test hits real datastores and asserts with Testing.Expect, so a failure
    raises with a readable message and a trimmed stack trace. running needs a place
    with studio api access: sync this folder next to the src folder (test.project.json
    builds that shape), then require it and call RunAll from the server.

    Return type: frozen table { RunAll, RunSuite, Run, Suites, Testing }
    Example usage:
        local Tests = require(ServerStorage.LedgerDev.Tests)
        Tests.RunAll()
        Tests.Run("TxCommitsSwap")
--]=]

local Testing = require("@self/Testing")

local Suites: { { Name: string, Tests: { [string]: () -> () } } } = {
	{ Name = "Log", Tests = require("@self/Log") :: any },
	{ Name = "Session", Tests = require("@self/Session") :: any },
	{ Name = "Reconcile", Tests = require("@self/Reconcile") :: any },
	{ Name = "Migrate", Tests = require("@self/Migrate") :: any },
	{ Name = "Recovery", Tests = require("@self/Recovery") :: any },
	{ Name = "Tx", Tests = require("@self/Tx") :: any },
	{ Name = "Guards", Tests = require("@self/Guards") :: any },
	{ Name = "Measure", Tests = require("@self/Measure") :: any },
	{ Name = "Transfers", Tests = require("@self/Transfers") :: any },
}

local function SortedNames(Tests: { [string]: () -> () }): { string }
	local Names = {}
	for Name in Tests do
		table.insert(Names, Name)
	end
	table.sort(Names)
	return Names
end

local function RunTests(Suite: { Name: string, Tests: { [string]: () -> () } })
	print(`{Suite.Name}`)
	Testing.Describe(Suite.Name, function()
		for _, Name in SortedNames(Suite.Tests) do
			Testing.Test(Name, Suite.Tests[Name])
		end
	end)
end

local function RunAll(): boolean
	Testing.Entry(function()
		for _, Suite in Suites do
			RunTests(Suite)
		end
	end)
	return Testing.Failed == 0
end

local function RunSuite(Name: string): boolean
	for _, Suite in Suites do
		if Suite.Name == Name then
			Testing.Entry(function()
				RunTests(Suite)
			end)
			return Testing.Failed == 0
		end
	end
	error(`no suite called '{Name}' exists`)
end

local function Run(Name: string): boolean
	for _, Suite in Suites do
		local Test = Suite.Tests[Name]
		if Test then
			Testing.Entry(function()
				Testing.Test(Name, Test)
			end)
			return Testing.Failed == 0
		end
	end
	error(`no test called '{Name}' exists`)
end

return table.freeze({
	RunAll = RunAll,
	RunSuite = RunSuite,
	Run = Run,
	Suites = Suites,
	Testing = Testing,
})
