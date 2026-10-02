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

	Test("a split quantity is declared with its parts, mode and stock, and one that cannot work throws", function()
		local Config: any = { Name = "Shop", Default = {}, Reducer = Reducer, Splits = { Swords = { Parts = 4, Stock = 100 } } }
		local Found = Build.Splits(Config).Swords
		Expect(Found.Parts).toBe(4)
		Expect(Found.Mode).toBe("Final")
		Expect(Found.Place).toBe("Shop$P:Swords:4")
		Expect(Found.Print).toBe(Build.Splits(Config).Swords.Print)
		Config.Splits.Swords.Stock = 101
		Expect(Build.Splits(Config).Swords.Print == Found.Print).toBe(false)
		for _, Bad in { { Parts = 0 }, { Parts = 65 }, { Parts = 2, Mode = "Shared" }, { Parts = 2, Stock = -1 }, { Parts = 2, Stock = 1.5 } } do
			Expect(function()
				Build.Splits({ Name = "Shop", Default = {}, Reducer = Reducer, Splits = { Swords = Bad :: any } })
			end).toThrow()
		end
		Expect(function()
			Build.Splits({ Name = "Shop", Default = {}, Reducer = Reducer, Splits = { [string.rep("a", 38)] = { Parts = 1 } } })
		end).toThrow("Ledger: a split quantity of Shop needs a name of 1 to 37 bytes")
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

	Test("a game sets its rooms within their bounds and all of them together within ROOMS_MAX", function()
		local Made = Build.New({ Name = "Gold", Default = { Gold = 0 }, Reducer = Reducer, Money = { "Gold" }, TimedRoom = 2048, LegLimit = 3 })
		Expect(Made.TimedRoom).toBe(2048)
		Expect(Made.LegLimit).toBe(3)
		Expect(Made.Erasable).toBe(false)
		Expect(Build.New({ Name = "Gold", Default = {}, Reducer = Reducer, MustExist = true }).Erasable).toBe(true)
		Expect(function()
			Build.New({ Name = "Gold", Default = {}, Reducer = Reducer, TimedRoom = 100 })
		end).toThrow("Ledger: the TimedRoom of Gold is not a whole number from 2048 to 32768")
		Expect(function()
			Build.New({ Name = "Gold", Default = {}, Reducer = Reducer, TimedRoom = 32768, UntimedRoom = 16384, WorkRoom = 4096 })
		end).toThrow("Ledger: the rooms of Gold take more than 49152 bytes together")
		Expect(function()
			Build.New({ Name = "Gold", Default = { Gold = 0 }, Reducer = Reducer, Money = { "Gold" }, LossRoom = 100 })
		end).toThrow("Ledger: the LossRoom of Gold is not a whole number from 160 to 16384")
		Expect(function()
			Build.New({ Name = "Gold", Default = {}, Reducer = Reducer, KeepNamed = 60 })
		end).toThrow("Ledger: the KeepNamed of Gold is not a whole number from 604800 to 2592000")
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
