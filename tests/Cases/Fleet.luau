--!strict
--!optimize 2

--[=[

	Fleet: One rule per promise the reap and sweep leases make to a fleet rather than to a pair.

	Twelve servers over one datastore reap one window and follow one key. They hand a shard with more
	names than one walk looks at down the line. The shards and the keys bound the cost the fleet pays,
	never the number of servers. Every marker still has to go.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau fleet
--]=]

local Suite = require("../Suite")

local Faults = require("../Suite/Fault")
local Cleanup = require("../../src/Protocol/Tx/Cleanup")
local Sweeper = require("../../src/Store/Sweeper")
local Transactions = require("../../src/Core/Constants/Transactions")

local Fault = Suite.Fault
local Windows = Suite.Horizons

type Case = Suite.Case
type Fixture = Suite.Fixture

local Cases = Suite.File("Fleet", { "cache" })

local SERVERS = 12
local START = 100
local SHARDS = Transactions.SHARDS
local LOOKS = Transactions.REAP_LOOKS

local function Fleet(T: Case): { Fixture }
	local Held: { Fixture } = {}
	for Index = 1, SERVERS do
		table.insert(Held, T:Bank(`n{Index}`))
	end
	return Held
end

local function Funded(Held: Fixture, A: string, B: string)
	Held:Seed(A, { Gold = START, Touches = 0 })
	Held:Seed(B, { Gold = 0, Touches = 0 })
end

local function Move(Held: Fixture, A: string, B: string, Amount: number, Id: string): (boolean, any)
	return Held.Store
		:Tx(Id, {
			{ Key = A, Kind = "Give", Fields = { Amount = -Amount } },
			{ Key = B, Kind = "Give", Fields = { Amount = Amount } },
		})
		:Wait()
end

local function Listing(Held: Fixture): Faults.Spec
	return Held.Hook.Fail(Fault.On("ListKeysAsync"):OnStore(Held.Marked):Only(999))
end

local function Units(T: Case, Body: () -> ()): number
	local Before = T.Service.Units
	Body()
	return T.Service.Units - Before
end

local function Reads(Held: Fixture, Body: () -> ()): number
	local Before = Held.Store.Wrapper.Spent
	Body()
	return Held.Store.Wrapper.Spent - Before
end

local function OnShard(Prefix: string, Count: number, Shard: number): { string }
	local Found: { string } = {}
	local Index = 0
	while #Found < Count do
		Index += 1
		local Id = `{Prefix}{Index}`
		if Cleanup.Shard(Id) == Shard then
			table.insert(Found, Id)
		end
	end
	return Found
end

Cases.Case("a fleet reaping one window lists each shard once, and every other server pays one read per shard", function(T: Case)
	local Servers = Fleet(T)
	local First = Servers[1]
	Funded(First, "fleetA", "fleetB")
	T:Ok("the transaction", (Move(First, "fleetA", "fleetB", 10, "fleet1")))
	T:Advance(Windows.REAP + 60)

	local Lists = 0
	local Spent: { number } = {}
	for Index, Held in Servers do
		local Listed = Listing(Held)
		Spent[Index] = Units(T, function()
			Held.Store:ReapMarkers()
		end)
		Lists += Listed.Count
	end

	T:Is("shards listed by the whole fleet", Lists, SHARDS)
	T:Is("units the first server spent, a read and a write per shard and no release", Spent[1], SHARDS * 3)
	T:Is("units the last server spent, one read per shard", Spent[SERVERS], SHARDS)
	T:Is("the marker is gone", First:Mark("fleet1"), nil)
	T:Is("its name is off the cleanup list", First:Rolled()["fleet1"], nil)
	T:Is("the money it moved is untouched", First:State("fleetB").Gold, 10)
end)

Cases.Case("a fleet following one key repairs it once a pass, and every other server pays one read", function(T: Case)
	local Servers = Fleet(T)
	local Now = T:Now()
	Servers[1]:Write("restA", {
		Snapshot = { Gold = 60, Touches = 0, _Held = { rest1 = { To = "restB", Amount = 40, At = Now - Windows.REDRIVE - 1 } } },
		Ops = {},
		Seen = {},
	})

	local Sweeps: { Sweeper.Sweeper } = {}
	for Index, Held in Servers do
		local Sweep = Sweeper.New()
		Sweep:Add(Held.Store:Swept(), "restA")
		Sweeps[Index] = Sweep
	end

	local Repaired = 0
	for Index, Held in Servers do
		local Read = Reads(Held, function()
			Sweeps[Index]:Pass()
		end)
		if Read > 0 then
			Repaired += 1
		end
	end

	local Again = 0
	for Index, Held in Servers do
		local Read = Reads(Held, function()
			Sweeps[Index]:Pass()
		end)
		if Read > 0 then
			Again += 1
		end
	end

	local Following = 0
	for _, Sweep in Sweeps do
		Following += Sweep.Count
		Sweep:Stop()
	end

	T:Is("servers that repaired the key on the first pass", Repaired, 1)
	T:Is("servers that repaired it on the second pass, the same one, whose lease it is", Again, 1)
	T:Is("servers still following it, since a skip is not a try", Following, SERVERS)
end)

Cases.Case("a shard with more names than one walk looks at is handed down the fleet until it is empty", function(T: Case)
	local Servers = Fleet(T)
	local First = Servers[1]
	local Shard = 0

	local Planted = 0
	for _, Count in { LOOKS, LOOKS, LOOKS // 4 } do
		for _, Id in OnShard(`hand{Planted}x`, Count, Shard) do
			First:Marker(Id, { Status = "Aborted", Total = 0, Adopted = {} })
			Planted += 1
		end
		T:Advance(Windows.BUCKET)
	end
	T:Advance(Windows.REAP_GRACE + 1)

	local Walks = 0
	local Reaped = 0
	for _, Held in Servers do
		local Listed = Listing(Held)
		Reaped += Held.Store:ReapMarkers()
		Walks += Listed.Count
	end

	T:Is("markers planted on one shard", Planted, LOOKS * 2 + LOOKS // 4)
	T:Is("markers the fleet reaped", Reaped, Planted)
	T:Is("walks the fleet made, three on the full shard and one on each other", Walks, SHARDS - 1 + 3)
	T:Is("markers left", #First:Marks(), 0)
end)

return Cases
