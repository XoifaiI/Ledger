--!strict

--[=[

	Quantities: The cases for Store/Quantities, run through the real runner on a datastore kept in
	memory.

	The quantity is Swords, one final part of 3 units with serials from 100. The server's number is
	set by hand, so nothing asks a counter key. Part reads what the part's key holds.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Future = require("../src/Util/Future")
local Game = require("./Gold")
local Ops = require("../src/Store/Ops")
local Parts = require("../src/Record/Parts")
local Quantities = require("../src/Store/Quantities")
local Runtime = require("../src/Store/Runtime")
local Shards = require("../src/Record/Shards")
local Value = require("../src/Encode/Value")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local PRINT = 4321
local SERVER = 9

local Keys: { [string]: unknown } = {}

local Memory = {
	GetAsync = function(_: any, Key: string): (unknown, DataStoreKeyInfo?)
		return Keys[Key], nil
	end,
	UpdateAsync = function(_: any, Key: string, Transform: (Current: unknown, Info: DataStoreKeyInfo?) -> ...any): (unknown, DataStoreKeyInfo?)
		local Next = Transform(Keys[Key], nil)
		if Next ~= nil then
			Keys[Key] = Next
		end
		return Next, nil
	end,
	RemoveAsync = function(_: any, Key: string): (unknown, DataStoreKeyInfo?)
		Keys[Key] = nil
		return nil, nil
	end,
}

local Declared: Parts.Declared = {
	Name = "Swords",
	Parts = 1,
	Mode = Parts.MODE.Final,
	Stock = 3,
	First = 100,
	Proceeds = {},
	Print = PRINT,
	Place = "Shop$P:Swords:1",
}

local Held: Quantities.Quantity = { Declared = Declared, View = {}, Total = Shards.New("Shop", "Swords", 1, Parts.KIND) }

Runtime.Shared.Places[Declared.Place] = { Store = Memory, Build = Parts.Build(Game.DEFAULT, Declared) }
Runtime.Shared.Taking = Future.Completed(SERVER)

local function Part(): Parts.Part
	return assert(Parts.Read(Keys[Parts.Key(Declared.Name, Declared.Parts, 0)]), "the part holds no state")
end

Describe("Quantities", function()
	Test("a hold sets units aside under an id its part can store, a confirm sells them, and a release gives them back", function()
		Expect(Quantities.Open(Held)).toBe(true)
		local Reply, Ticket = Quantities.Hold(Held, 1, 60)
		Expect(Reply).toBe(true)
		local First = assert(Ticket, "the hold gave no ticket")
		Expect((Value.Check({ Id = First.Id }))).never.toBeNil()
		Expect(First.Part).toBe(0)
		Expect((First.Serials :: { number })[1]).toBe(100)
		Expect(Part().Free).toBe(2)
		Expect(Part().Holds[1].Id).toBe(First.Id)

		local Sold, Taken = Quantities.Confirm(Held, Ops.Body("Confirm", { Id = First.Id, Count = 1, Print = PRINT }), {}, First.Part)
		Expect(Sold).toBe(true)
		Expect(Taken.Value).toBe(100)
		Expect(Part().Sold).toBe(1)
		Expect(#Part().Holds).toBe(0)

		local Again, Other = Quantities.Hold(Held, 2, 60)
		Expect(Again).toBe(true)
		local Second = assert(Other, "the second hold gave no ticket")
		Expect(Second.Id == First.Id).toBe(false)
		Expect(Part().Free).toBe(0)
		Expect(Quantities.Release(Held, Ops.Body("Release", { Id = Second.Id, Print = PRINT }), Second.Part)).toBe(true)
		Expect(Part().Free).toBe(2)
		Expect(Part().Sold).toBe(1)
	end)
end)

return nil
