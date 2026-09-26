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
local ROOM = Transactions.REAP_LIMIT

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

	T:Is("shards listed by the whole fleet, plus the one older block the rotation lists", Lists, SHARDS + 1)
	T:Is("units the first server spent, a read and a write per shard and for the older block it claims, and no release", Spent[1], (SHARDS + 1) * 3)
	T:Is("units the last server spent, one read per shard and one for the older block another server claimed", Spent[SERVERS], SHARDS + 1)
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

	local Planted = 0
	for _, Count in { ROOM, ROOM, ROOM // 4 } do
		for _ = 1, Count do
			Planted += 1
			First:Marker(`hand{Planted}`, { Status = "Aborted", Total = 0, Adopted = {} })
		end
		T:Advance(Windows.BUCKET)
	end
	T:Advance(Windows.REAP_GRACE + 1)

	local Walks = 0
	local Reaped = 0
	local Rotated = 0
	for _, Held in Servers do
		local Listed = Listing(Held)
		Reaped += Held.Store:ReapMarkers()
		Walks += Listed.Count
		Rotated += if Held.Store.Reaping.Shard ~= 0 then 1 else 0
	end

	T:Is("markers planted on one shard", Planted, ROOM * 2 + ROOM // 4)
	T:Is("markers the fleet reaped", Reaped, Planted)
	T:Ok("servers whose walk back was due on an older block", Rotated > 1)
	T:Is("walks the fleet made, three on the full shard, one on each other, and the older block once, by the server that claimed it", Walks, SHARDS - 1 + 3 + 1)
	T:Is("markers left", #First:Marks(), 0)
end)

Cases.Case("a fleet clears a thousand markers in a round of passes, and what a full walk carried on in the next", function(T: Case)
	local Servers = Fleet(T)
	local First = Servers[1]
	local Planted = 1000
	for Index = 1, Planted do
		Servers[Index % SERVERS + 1]:Marker(`round{Index}`, { Status = "Aborted", Total = 0, Adopted = {} })
	end
	T:Advance(Windows.REAP_GRACE + 1)
	for _, Held in Servers do
		Held:Budget(function(): number
			return 1000
		end)
		Held:MarkerBudget(function(): number
			return 1000
		end)
	end

	local Reaped = 0
	for _, Held in Servers do
		Reaped += Held.Store:ReapMarkers()
	end
	local Round = Reaped

	T:Advance(Windows.REAP_GRACE + 1)
	for _, Held in Servers do
		Reaped += Held.Store:ReapMarkers()
	end

	T:Ok("most of the markers went in the first round, far past the sixteen a walk used to look at per shard", Round > Planted - SHARDS * 8)
	T:Is("all of them once the carried names aged past the grace", Reaped, Planted)
	T:Is("markers left", #First:Marks(), 0)
end)

return Cases
