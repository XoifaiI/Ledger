--!strict

--[=[

	Build: The cases for Store/Build.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Build = require("../src/Store/Build")
local Ops = require("../src/Store/Ops")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local function Reducer(State: any): unknown
	return State
end

local function Step(State: any): unknown
	return State
end

Describe("Build", function()
	Test("a config declares Default's fields, and its floor is the last migration that breaks", function()
		local Made = Build.New({
			Name = "Gold",
			Default = { Gold = 0, Items = {} },
			Reducer = Reducer,
			Money = { "Gold" },
			Migrations = { Step, { Apply = Step, Compatible = true }, { Apply = Step }, { Apply = Step, Compatible = true } },
		})
		Expect(Made.Fields.Gold).toBe(true)
		Expect(Made.Fields.Items).toBe(true)
		Expect(Made.Level).toBe(4)
		Expect(Made.Floor).toBe(3)
		Expect(Made.Migrations[2]).toBe(Step)
	end)

	Test("a config that cannot work throws at the call", function()
		Expect(function()
			Build.New({ Name = "", Default = {}, Reducer = Reducer })
		end).toThrow("Ledger: a store needs a Name")
		Expect(function()
			Build.New({ Name = "Gold", Default = { Gold = "x" }, Reducer = Reducer, Money = { "Gold" } })
		end).toThrow("Ledger: the money field Gold of Gold is not a number in Default")
		Expect(function()
			Build.New({ Name = "Gold", Default = {}, Reducer = Reducer, Migrations = { 5 :: any } })
		end).toThrow("Ledger: migration 1 is not a function or a table with Apply")
	end)

	Test("a kind's window is kept under the number its name hashes to, and one out of range throws", function()
		local Made = Build.New({ Name = "Gold", Default = {}, Reducer = Reducer, Windows = { Grant = 3600 } })
		Expect(Made.Window[Ops.Kind("Grant")]).toBe(3600)
		Expect(function()
			Build.New({ Name = "Gold", Default = {}, Reducer = Reducer, Windows = { Grant = 10 } })
		end).toThrow("Ledger: the window of Grant in Gold is not from 180 to 2592000 seconds")
	end)
end)

return nil
