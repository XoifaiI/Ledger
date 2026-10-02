--!strict

--[=[

	Bumps: The cases for Store/Totals.Bump, run through the real runner on a datastore kept in memory.

	The total is Coins, on 4 shards. The server's number is set by hand, so nothing asks a counter
	key. A new paced queue waits a random time before its first send, so each case makes the queues
	first and clears that wait. Sum reads what a shard's key holds.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Future = require("../src/Util/Future")
local Game = require("./Gold")
local Key = require("../src/Record/Key")
local Pacing = require("../src/Record/Pacing")
local Runtime = require("../src/Store/Runtime")
local Shards = require("../src/Record/Shards")
local Totals = require("../src/Store/Totals")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local SERVER = 9
local COUNT = 4

local Keys: { [string]: unknown } = {}

local Memory = {
	GetAsync = function(_: any, Name: string): (unknown, DataStoreKeyInfo?)
		return Keys[Name], nil
	end,
	UpdateAsync = function(_: any, Name: string, Transform: (Current: unknown, Info: DataStoreKeyInfo?) -> ...any): (unknown, DataStoreKeyInfo?)
		local Next = Transform(Keys[Name], nil)
		if Next ~= nil then
			Keys[Name] = Next
		end
		return Next, nil
	end,
	RemoveAsync = function(_: any, Name: string): (unknown, DataStoreKeyInfo?)
		Keys[Name] = nil
		return nil, nil
	end,
}

local Shared = Runtime.Shared
local Declared: Totals.Declared = {}

Shared.Taking = Future.Completed(SERVER)
Totals.Declare(Declared, "Shop", Memory :: any, Game.DEFAULT, { Coins = COUNT })

local Held = Declared.Coins

local function Sum(Index: number): number?
	local Found = Key.Read(Keys[Shards.Key(Held.Name, Held.Shards, Index)])
	return if type(Found) == "table" then Found.State.Sum else nil
end

local function Named(Index: number): string
	for Try = 1, 1000 do
		local Name = `gift-{Try}`
		if Shards.Named(Name, COUNT) == Index then
			return Name
		end
	end
	error("no name hashes to the shard")
end

Describe("Bumps", function()
	Test("a named bump lands on the shard its name hashes to, and a bump with no name on this server's home shard (TotCtlNameHash)", function()
		for Index = 0, COUNT - 1 do
			local Kept = Shared:SaveFor({ Store = Held.Place, Key = Shards.Key(Held.Name, Held.Shards, Index) })
			Pacing.Failed(Kept.Pace)
		end
		local Home = Shards.Home(Held.Name, SERVER, COUNT)
		local Away = (Home + 1) % COUNT
		Expect(Totals.Bump(Held, 5, Named(Away))).toBe(true)
		Expect(Sum(Away)).toBe(5)
		Expect(Sum(Home)).toBeNil()
		Expect(Totals.Bump(Held, 2)).toBe(true)
		Expect(Sum(Home)).toBe(2)
		Expect(Sum(Away)).toBe(5)
	end)
end)

return nil
