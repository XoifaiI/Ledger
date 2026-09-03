--!strict
--!optimize 2

--[=[

	Leases: One rule per promise the lease before a transaction makes.

	A coordinator leases each leg's key before it drives, and lets go on every exit. A second
	coordinator meeting a held lease answers Busy at once, for one unit and no datastore call. A lease
	it cannot take or read means drive without one. A lease nobody lets go of answers Busy until it
	runs out. A starved server takes none.

	No server waits on another, and the marker still decides all of it. The reaper and the sweep claim
	a lease per shard and per followed key the same way. A skip is not a try.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau leases
--]=]

local Suite = require("../Suite")

local Faults = require("../Suite/Fault")
local Mark = require("../../src/Encode/Mark")
local Cleanup = require("../../src/Protocol/Tx/Cleanup")
local Registry = require("../../src/Store/Registry")
local Transactions = require("../../src/Core/Constants/Transactions")

local Fault = Suite.Fault
local Windows = Suite.Horizons

type Case = Suite.Case
type Fixture = Suite.Fixture

local Cases = Suite.File("Leases", { "cache" })

local START = 100
local MAP = Transactions.LEASE_MAP

local function Pair(T: Case): (Fixture, Fixture)
	return T:Bank("nodeA"), T:Bank("nodeB")
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

local function Gold(Held: Fixture, Key: string): number
	return Held:State(Key).Gold
end

local function Lease(Held: Fixture, Key: string): string
	return Mark.Cached({ "tx", Held.Data, Key })
end

local function Holder(T: Case, Held: Fixture, Key: string): any
	return T.Service:GetHashMap(MAP):GetAsync(Lease(Held, Key))
end

local function Plant(T: Case, Held: Fixture, Key: string, Node: string)
	T.Service:GetHashMap(MAP):SetAsync(Lease(Held, Key), Node, Windows.TX_LEASE)
end

local function Faulted(Held: Fixture, Spec: Faults.Spec): Faults.Spec
	return Held.Hook.Fail(Spec:OnStore(MAP))
end

local function Units(T: Case, Body: () -> ()): number
	local Before = T.Service.Units
	Body()
	return T.Service.Units - Before
end

local function Calls(One: Fixture, Two: Fixture): number
	return One.Store.Wrapper.Spent + Two.Store.Wrapper.Spent + One.Store.TxWrapper.Spent + Two.Store.TxWrapper.Spent
end

Cases.Case("a transaction leases each of its keys while it drives and lets go on every exit", function(T: Case)
	local Bank = T:Bank("nodeA")
	Funded(Bank, "leaseA", "leaseB")

	local Seen: { any } = {}
	Bank:MarkerFault(Fault.Updates():Only(2):Meddle(function()
		Seen = { Holder(T, Bank, "leaseA"), Holder(T, Bank, "leaseB") }
	end))
	local Ok
	local Spent = Units(T, function()
		Ok = Move(Bank, "leaseA", "leaseB", 30, "lease1")
	end)
	local AfterOk = { Holder(T, Bank, "leaseA"), Holder(T, Bank, "leaseB") }

	local Refused, Why
	local Turned = Units(T, function()
		Refused, Why = Move(Bank, "leaseA", "leaseB", 500, "lease2")
	end)
	local AfterNo = { Holder(T, Bank, "leaseA"), Holder(T, Bank, "leaseB") }

	T:Ok("the transaction", Ok)
	T:Is("the sender's lease while it drove, held by this server", Seen[1], Bank.Node)
	T:Is("the receiver's lease while it drove, held by this server", Seen[2], Bank.Node)
	T:Is("the sender's lease once it was told yes", AfterOk[1], nil)
	T:Is("the receiver's lease once it was told yes", AfterOk[2], nil)
	T:No("a transaction the reducer turned away", Refused)
	T:Is("the reason", Why, Suite.Reasons.Refused)
	T:Is("the sender's lease once it was told no", AfterNo[1], nil)
	T:Is("the receiver's lease once it was told no", AfterNo[2], nil)
	T:Is("units the drive spent, two keys read and taken and two let go, and the two reads the meddle made", Spent, 2 * 3 + 2 * 1 + 2)
	T:Is("units the refused drive spent, two keys read and taken and two let go", Turned, 2 * 3 + 2 * 1)
end)

Cases.Case("a second coordinator meets a held lease and answers Busy at once, for one unit and no datastore call", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "waitA", "waitB")

	local First, Second, Why: any = nil, nil, nil
	local Before = T:Now()
	local Spent = Calls(Two, Two)
	local Looked = Two.Store.Leases.Spent
	T:Race({
		function()
			First = Move(One, "waitA", "waitB", 30, "wait1")
		end,
		function()
			Second, Why = Move(Two, "waitA", "waitB", 40, "wait2")
		end,
	})

	T:Ok("the first server was told yes", First)
	T:No("the second server was told no", Second)
	T:Is("and why", Why, Suite.Reasons.Busy)
	T:Is("datastore calls the second server made", Calls(Two, Two) - Spent, 0)
	T:Ok(`map calls the second server made, a read and at most one lost write, {Two.Store.Leases.Spent - Looked}`, Two.Store.Leases.Spent - Looked <= 2)
	T:Is("time it waited", T:Now() - Before, 0)
	T:Is("the sender after both", Gold(One, "waitA"), START - 30)
	T:Is("the receiver after both", Gold(One, "waitB"), 30)
	T:Is("nothing left parked on the sender", One:Pending("waitA"), false)
end)

Cases.Case("two coordinators crossing on the same keys lease them in one order, so one of them always goes through", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "orderA", "orderB")

	local First, Second: any = nil, nil
	local Before = T:Now()
	T:Race({
		function()
			First = Move(One, "orderA", "orderB", 10, "order1")
		end,
		function()
			Second = Move(Two, "orderB", "orderA", 0.5, "order2")
		end,
	})

	T:Ok("exactly one of the two was told yes", (First == true) ~= (Second == true))
	T:Is("the money adds up", Gold(One, "orderA") + Gold(One, "orderB"), START)
	T:Is("nobody waited", T:Now() - Before, 0)
end)

Cases.Case("an acquire that cannot reach the map drives as today, and one that misses on the second key lets the first go", function(T: Case)
	local Bank = T:Bank("nodeA")
	Funded(Bank, "missA", "missB")

	local Down = Faulted(Bank, Fault.Updates())
	local Ok = Move(Bank, "missA", "missB", 30, "miss1")
	local Moved = Gold(Bank, "missB")
	Bank:Healed()

	local Second = Faulted(Bank, Fault.Updates():Only(2))
	local Again = Move(Bank, "missA", "missB", 20, "miss2")

	T:Ok("the transaction with the map down", Ok)
	T:Ok("the map was asked and did not answer", Down.Fired > 0)
	T:Is("the receiver", Moved, 30)
	T:Ok("the transaction whose second acquire missed", Again)
	T:Is("the receiver after both", Gold(Bank, "missB"), 50)
	T:Is("the second acquire was the one that missed", Second.Fired, 1)
	T:Is("the first key's lease, let go before the drive", Holder(T, Bank, "missA"), nil)
	T:Is("the second key's lease", Holder(T, Bank, "missB"), nil)
	T:Warns("it said the map did not answer", "did not answer")
end)

Cases.Case("a lease nobody lets go of answers Busy until its time runs out, and never a write", function(T: Case)
	local Bank = T:Bank("nodeA")
	Funded(Bank, "deadA", "deadB")
	Plant(T, Bank, "deadA", "gone")

	local Written = Faulted(Bank, Fault.Updates():Only(999))
	local Before = T:Now()
	local Refused, Why = Move(Bank, "deadA", "deadB", 30, "dead1")
	local Waited = T:Now() - Before
	local Wrote = Written.Count

	T:Advance(Windows.TX_LEASE + 1)
	local Ok = Move(Bank, "deadA", "deadB", 30, "dead2")

	T:No("the transaction while the dead lease stood", Refused)
	T:Is("and why", Why, Suite.Reasons.Busy)
	T:Is("time it waited", Waited, 0)
	T:Is("writes it made to the map while the lease stood", Wrote, 0)
	T:Is("the dead lease once its time ran out", Holder(T, Bank, "deadA"), nil)
	T:Ok("the transaction once it had", Ok)
	T:Is("the receiver", Gold(Bank, "deadB"), 30)
end)

Cases.Case("a swallowed acquire leaves a phantom lease that costs a second server a Busy until it runs out, and nothing else", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "ghostA", "ghostB")

	local Spec = Faulted(One, Fault.Updates():Only(1):Swallow())
	local First = Move(One, "ghostA", "ghostB", 30, "ghost1")
	local Phantom = Holder(T, One, "ghostA")

	local Second, Why = Move(Two, "ghostA", "ghostB", 20, "ghost2")
	T:Advance(Windows.TX_LEASE + 1)
	local Third = Move(Two, "ghostA", "ghostB", 20, "ghost3")

	T:Is("the swallowed acquire fired", Spec.Fired, 1)
	T:Ok("the first server, which believed it held nothing, went through", First)
	T:Is("the lease it did not know it held", Phantom, One.Node)
	T:No("the second server, against the phantom", Second)
	T:Is("and why", Why, Suite.Reasons.Busy)
	T:Ok("the second server once the phantom ran out", Third)
	T:Is("the receiver after both", Gold(One, "ghostB"), 50)
end)

Cases.Case("a lease evicted mid drive costs nothing but the scramble it was saving", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "evictA", "evictB")

	One:Fault(Fault.Updates():Only(1):Meddle(function()
		T.Service:GetHashMap(MAP):RemoveAsync(Lease(One, "evictA"))
		T.Service:GetHashMap(MAP):RemoveAsync(Lease(One, "evictB"))
	end))

	local First, Second: any = nil, nil
	T:Race({
		function()
			First = Move(One, "evictA", "evictB", 30, "evict1")
		end,
		function()
			Second = Move(Two, "evictA", "evictB", 40, "evict2")
		end,
	})

	local Left, Right = Gold(One, "evictA"), Gold(One, "evictB")
	T:Is("the money adds up", Left + Right, START)
	T:Ok("what moved is one of the two, or both, never a part", Right == 0 or Right == 30 or Right == 40 or Right == 70)
	T:Is("a server told yes is on the key", ((First == true) and 30 or 0) + ((Second == true) and 40 or 0), Right)
	T:Is("nothing left parked on the sender", One:Pending("evictA"), false)
	T:Is("nothing left parked on the receiver", One:Pending("evictB"), false)
end)

Cases.Case("a drive that runs more than one pass holds its leases throughout", function(T: Case)
	local Bank = T:Bank("nodeA")
	Funded(Bank, "passA", "passB")

	local Counted = Faulted(Bank, Fault.Updates():Only(999))
	Bank:MarkerFault(Fault.Updates():Only(2))
	local Ok = Move(Bank, "passA", "passB", 30, "pass1")

	T:Ok("the transaction, on its second pass", Ok)
	T:Is("acquires the whole drive made, one per key", Counted.Count, 2)
	T:Is("the sender's lease afterwards", Holder(T, Bank, "passA"), nil)
end)

Cases.Case("a starved server takes no lease", function(T: Case)
	local Bank = T:Bank("nodeA")
	Funded(Bank, "poorA", "poorB")
	Bank:Budget(function(_Kind: Enum.DataStoreRequestType): number
		return Transactions.LEASE_BUDGET - 1
	end)

	local Counted = Faulted(Bank, Fault.Updates():Only(999))
	local Ok = Move(Bank, "poorA", "poorB", 30, "poor1")

	T:Ok("the transaction", Ok)
	T:Is("acquires a server short of budget made", Counted.Count, 0)
end)

Cases.Case("two servers contending on one bank key spend fewer datastore calls per success with leases than without", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "costA", "costB")

	local Before = Calls(One, Two)
	local Wins = 0
	T:Race({
		function()
			if Move(One, "costA", "costB", 10, "cost1") then
				Wins += 1
			end
		end,
		function()
			if Move(Two, "costA", "costB", 10, "cost2") then
				Wins += 1
			end
		end,
	})
	local Leased = (Calls(One, Two) - Before) / math.max(Wins, 1)

	Funded(One, "bareA", "bareB")
	Faulted(One, Fault.Updates())
	Faulted(Two, Fault.Updates())
	local Middle = Calls(One, Two)
	local BareWins = 0
	T:Race({
		function()
			if Move(One, "bareA", "bareB", 10, "bare1") then
				BareWins += 1
			end
		end,
		function()
			if Move(Two, "bareA", "bareB", 10, "bare2") then
				BareWins += 1
			end
		end,
	})
	local Bare = (Calls(One, Two) - Middle) / math.max(BareWins, 1)

	T:Is("the money adds up with leases", Gold(One, "costA") + Gold(One, "costB"), START)
	T:Is("the money adds up without", Gold(One, "bareA") + Gold(One, "bareB"), START)
	T:Is("one went through with leases and the other answered Busy for no datastore calls", Wins, 1)
	T:Ok(`datastore calls per success with leases, {Leased}, below those without, {Bare}`, Leased < Bare)
end)

local function Listing(Held: Fixture): Faults.Spec
	return Held.Hook.Fail(Fault.On("ListKeysAsync"):OnStore(Held.Marked):Only(999))
end

local function Claims(Held: Fixture): Faults.Spec
	return Faulted(Held, Fault.Updates():Only(999))
end

local function Shard(Held: Fixture, Index: number): string
	return Mark.Cached({ "reap", Held.Marked, tostring(Index) })
end

local function Followed(Held: Fixture, Key: string): string
	return Mark.Cached({ "sweep", Held.Data, Key })
end

Cases.Case("two servers reaping at once: one lists a shard while the other skips it and walks on", function(T: Case)
	local One, Two = Pair(T)
	Funded(One, "reapA", "reapB")
	T:Ok("the transaction", (Move(One, "reapA", "reapB", 10, "reap1")))
	T:Advance(Windows.REAP + 60)

	local Listed = Listing(Two)
	local Inside: number? = nil
	One.Hook.Fail(Fault.On("ListKeysAsync"):OnStore(One.Marked):Only(1):Meddle(function()
		Two.Store:ReapMarkers()
		Inside = Listed.Count
	end))
	One.Store:ReapMarkers()

	T:Is("shards the other server listed while this one held the first, every one but that", Inside, Transactions.SHARDS - 1)
	T:Is("where the other server's next pass starts, a whole round on", Two.Store.Resume, Cleanup.Mine("nodeB"))
	T:Is("the marker is gone", One:Mark("reap1"), nil)
	T:Is("its name is off the cleanup list", One:Rolled()["reap1"], nil)
	T:Is("the money it moved is untouched", Gold(One, "reapB"), 10)
end)

Cases.Case("a followed key another server holds is skipped without counting as a try", function(T: Case)
	local One = T:Bank("nodeA")
	Funded(One, "holdA", "holdB")
	T.Service:GetHashMap(MAP):SetAsync(Followed(One, "holdA"), "other", Windows.PASS_LEASE)

	local Sweep = Registry.Sweep()
	Sweep:Add(One.Store:Swept(), "holdA")
	local Held = One.Store:Mark("holdA")

	local Before = One.Store.Wrapper.Spent
	T:Sweep()
	local Skipped = Sweep.Entries[Held]
	local Tries = if Skipped ~= nil then Skipped.Tries else nil
	local Read = One.Store.Wrapper.Spent - Before

	T:Advance(Windows.PASS_LEASE + 1)
	T:Sweep()

	T:Ok("the key is still followed after the skip", Skipped ~= nil)
	T:Is("its tries after the skip", Tries, 0)
	T:Is("datastore calls the skip spent", Read, 0)
	T:Is("the key once the lease ran out and a pass repaired it clean", Sweep.Entries[Held], nil)
	T:Ok("that pass read the key", One.Store.Wrapper.Spent > Before)
end)

Cases.Case("a claim that cannot reach the map holds a background reap to one shard, and an operator still gets the whole walk", function(T: Case)
	local One = T:Bank("nodeA")
	Funded(One, "downA", "downB")
	Faulted(One, Fault.Updates())

	local Listed = Listing(One)
	One.Store:ReapMarkers(true)
	local First = Listed.Count
	local Onward = One.Store.Resume
	One.Store:ReapMarkers(true)
	local Second = Listed.Count - First
	One.Store:ReapMarkers()

	T:Is("shards a background pass listed with the map down", First, 1)
	T:Is("the shard its next pass starts on, one past the one it walked", Onward, (Cleanup.Mine("nodeA") + 1) % Transactions.SHARDS)
	T:Is("shards the pass after that listed", Second, 1)
	T:Is("shards an operator's reap listed", Listed.Count - First - Second, Transactions.SHARDS)
	T:Warns("it said the map did not answer", "did not answer")
end)

Cases.Case("a followed key that never comes clean does not hold up the ones behind it", function(T: Case)
	local One = T:Bank("nodeA")
	Funded(One, "sweepA", "sweepB")
	Faulted(One, Fault.Updates())
	One:NoRetries()
	One:Fault(Fault.Reads():OnKey("sweepA"))

	local Sweep = Registry.Sweep()
	Sweep:Add(One.Store:Swept(), "sweepA")
	Sweep:Add(One.Store:Swept(), "sweepB")
	local Stuck, Clean = One.Store:Mark("sweepA"), One.Store:Mark("sweepB")

	T:Sweep()
	local FirstPass = Sweep.Entries[Clean] ~= nil
	T:Sweep()

	T:Ok("the key that cannot be read is still followed", Sweep.Entries[Stuck] ~= nil)
	T:Ok("the key behind it, still followed after the pass that took the stuck one", FirstPass)
	T:Is("the key behind it once the next pass reached it", Sweep.Entries[Clean], nil)
end)

Cases.Case("one server with the map down still reaps every shard, over as many passes as there are shards", function(T: Case)
	local One = T:Bank("nodeA")
	Funded(One, "roundA", "roundB")
	Faulted(One, Fault.Updates())

	local Seen: { [number]: boolean } = {}
	local Walked = 0
	for _ = 1, Transactions.SHARDS do
		local At = One.Store.Resume or Cleanup.Mine("nodeA")
		if not Seen[At] then
			Seen[At] = true
			Walked += 1
		end
		One.Store:ReapMarkers(true)
	end

	T:Is("shards it started a pass on, every one of them", Walked, Transactions.SHARDS)
	T:Is("where it is after a full round", One.Store.Resume, Cleanup.Mine("nodeA"))
end)

Cases.Case("a claim that cannot reach the map repairs one followed key a pass and leaves the rest followed", function(T: Case)
	local One = T:Bank("nodeA")
	Funded(One, "downA", "downB")
	One:Seed("downC", { Gold = 0, Touches = 0 })
	Faulted(One, Fault.Updates())

	local Sweep = Registry.Sweep()
	local Keys = { "downA", "downB", "downC" }
	local Marks: { string } = table.create(#Keys) :: { string }
	for Index, Key in Keys do
		Sweep:Add(One.Store:Swept(), Key)
		Marks[Index] = One.Store:Mark(Key)
	end

	local function Left(): number
		local Count = 0
		for _, Held in Marks do
			if Sweep.Entries[Held] ~= nil then
				Count += 1
			end
		end
		return Count
	end

	local Before = One.Store.Wrapper.Spent
	T:Sweep()
	local After = Left()
	local Tries = 0
	for _, Held in Marks do
		local Entry = Sweep.Entries[Held]
		Tries += if Entry ~= nil then Entry.Tries else 0
	end

	T:Ok("the pass read the one key it repaired", One.Store.Wrapper.Spent > Before)
	T:Is("keys still followed after one pass", After, 2)
	T:Is("tries the keys it left carry, since a skip is not a try", Tries, 0)
	T:Sweep()
	T:Is("keys still followed after another", Left(), 1)
	T:Sweep()
	T:Is("keys still followed after a third", Left(), 0)
end)

Cases.Case("a crashed holder's lease on a shard runs out and the next pass takes it", function(T: Case)
	local One = T:Bank("nodeA")
	local Dead = Cleanup.Mine("nodeA")
	T.Service:GetHashMap(MAP):SetAsync(Shard(One, Dead), "gone", Windows.PASS_LEASE)

	local Listed = Listing(One)
	One.Store:ReapMarkers()
	local Skipping = Listed.Count

	T:Advance(Windows.PASS_LEASE + 1)
	One.Store:ReapMarkers()

	T:Is("shards listed while a dead server held one", Skipping, Transactions.SHARDS - 1)
	T:Is("shards listed once its lease ran out", Listed.Count - Skipping, Transactions.SHARDS)
end)

Cases.Case("a starved server takes no lease on a shard or a followed key, and Resettle takes none at all", function(T: Case)
	local One = T:Bank("nodeA")
	Funded(One, "poorA", "poorB")

	local Counted = Claims(One)
	One.Store:Resettle("poorA"):Wait()
	local Resettled = Counted.Count

	One:Budget(function(_Kind: Enum.DataStoreRequestType): number
		return 0
	end)
	One:MarkerBudget(function(_Kind: Enum.DataStoreRequestType): number
		return 0
	end)
	Registry.Sweep():Add(One.Store:Swept(), "poorA")
	T:Sweep()
	One.Store:ReapMarkers()

	T:Is("claims a Resettle made", Resettled, 0)
	T:Is("claims a starved sweep and reap made", Counted.Count, 0)
end)

return Cases
