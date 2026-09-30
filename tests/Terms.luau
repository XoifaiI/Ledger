--!strict

--[=[

	Terms: The cases for Store/Terms.

	Every leg is in the store of tests/Gold, whose money field is Gold.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Game = require("./Gold")
local Terms = require("../src/Store/Terms")
local Asks = require("../src/Machine/Asks")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local PLACE: Asks.Place = { Store = nil :: any, Build = Game.DEFAULT }

local function Leg(Key: string, Change: { [string]: any }): Terms.Given
	return {
		Ref = { Store = "Gold", Key = Key },
		Place = PLACE,
		MustExist = true,
		Field = Change.Field,
		Amount = Change.Amount,
		Kind = Change.Kind,
		Fields = Change.Fields,
	}
end

local function Delta(Key: string, Amount: number): Terms.Given
	return Leg(Key, { Field = "Gold", Amount = Amount })
end

local function Op(Key: string): Terms.Given
	return Leg(Key, { Kind = "Add", Fields = { Add = 1 } })
end

Describe("Terms", function()
	Test("the decider is the hot leg, else the one game op, else the first credit, else the last leg", function()
		Expect(Terms.Make({ Delta("a", -5), Delta("b", 5) }, nil, nil).Decider).toBe(2)
		Expect(Terms.Make({ Delta("a", -5), Delta("b", 5) }, nil, 1).Decider).toBe(1)
		Expect(Terms.Make({ Delta("a", -5), Op("b"), Delta("c", 5) }, nil, nil).Decider).toBe(2)
		Expect(Terms.Make({ Op("a"), Op("b"), Delta("c", 5) }, nil, nil).Decider).toBe(3)
		Expect(Terms.Make({ Delta("a", 5), Delta("b", -5) }, nil, nil).Decider).toBe(1)
		Expect(Terms.Make({ Delta("a", -5), Delta("b", -1) }, nil, nil).Decider).toBe(2)
	end)

	Test("a game name's print follows its terms, and a drawn name has none", function()
		local First = Terms.Make({ Delta("a", -5), Delta("b", 5) }, "trade", nil).Print
		Expect(First).never.toBeNil()
		Expect(Terms.Make({ Delta("a", -5), Delta("b", 5) }, "trade", nil).Print).toBe(First)
		Expect(Terms.Make({ Delta("a", -6), Delta("b", 6) }, "trade", nil).Print).never.toBe(First)
		Expect(Terms.Make({ Delta("a", -5), Delta("b", 5) }, "trade", 1).Print).never.toBe(First)
		Expect(Terms.Make({ Delta("a", -5), Delta("b", 5) }, nil, nil).Print).toBeNil()
	end)

	Test("a call that cannot run throws at the game's call", function()
		Expect(function()
			Terms.Make({ Delta("a", -5) }, nil, nil)
		end).toThrow("Ledger: a transaction needs at least two legs")
		Expect(function()
			Terms.Make({ Delta("a", -5), Delta("a", 5) }, nil, nil)
		end).toThrow("Ledger: two legs are on the key Gold/a")
		Expect(function()
			Terms.Make({ Leg("a", { Field = "Gems", Amount = -5 }), Delta("b", 5) }, nil, nil)
		end).toThrow("Ledger: leg 1 needs Field, a money field of its store, and Amount, a whole number of size 1 to 2^53")
		Expect(function()
			Terms.Make({ Delta("a", 0), Delta("b", 5) }, nil, nil)
		end).toThrow("Ledger: leg 1 needs Field, a money field of its store, and Amount, a whole number of size 1 to 2^53")
		Expect(function()
			Terms.Make({ Delta("a", -5), Leg("b", { Kind = "Add", Fields = { Once = "x" } }) }, nil, nil)
		end).toThrow("Ledger: leg 2 carries Once, which names the whole transaction instead")
		Expect(function()
			Terms.Make({ Delta("a", -5), Delta("b", 5) }, nil, 3)
		end).toThrow("Ledger: Hot has to be the index of one of the legs")
		local Many: { Terms.Given } = {}
		for Index = 1, 40 do
			Many[Index] = Delta(`key-{Index}-{string.rep("k", 16)}`, if Index == 1 then 39 else -1)
		end
		Expect(function()
			Terms.Make(Many, nil, nil)
		end).toThrow("Ledger: the legs do not fit in 512 bytes. use fewer legs or shorter keys")
	end)
end)

return nil
