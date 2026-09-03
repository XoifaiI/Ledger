--!strict
--!optimize 2

--[=[

	Booking: One rule per case for the units that cross keys, and for tallies.

	Units cross keys with Transfer and a Field, so the transfer cases for a field are here. A confirm
	is the game's own op, whether or not a hold stands behind it. The hold cases are in Holds, since a
	hold needs a MemoryStore and these do not. The tally cases are the other half.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau booking
--]=]

local Suite = require("../Suite")

local Ledger = require("../../src") :: any
local Engine = require("../../src/Util/Engine")
local Windows = require("../../src/Core/Constants/Windows")
local Shards = require("../../src/Core/Constants/Shards")
local Tally = require("../../src/Layers/Tally")

local Fault = Suite.Fault
local Reducers = Suite.Reducers

type Case = Suite.Case
type Fixture = Suite.Fixture

local Cases = Suite.File("Booking")

local function Sell(Shelf: Fixture, Key: string, Rid: string, Count: number): (boolean, any)
	return Shelf.Store:Confirm(Key, Rid, "Sell", { Count = Count }):Wait()
end

Cases.Case("a store with no MemoryStore cannot hold and says so once", function(T: Case)
	local Hook: Engine.Hook = { Open = T.Hook.Open, Budget = T.Hook.Budget, Cache = nil }
	local Store = Ledger.New({ Name = "CaseBookingBare", Keys = "String", Default = Reducers.SHELF, Reducer = Reducers.Shopkeeper, Hook = Hook })

	local Ok, Why = Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()
	local Held, HeldWhy = Store:Holds("shelf", "Stock"):Wait()
	local Sold = Store:Confirm("shelf", "cart1", "Sell", { Count = 3 }):Wait()

	T:Is("the reservation", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("what Holds answers", Held, nil)
	T:Is("its reason", HeldWhy, "Unresolved")
	T:Is("a checkout, which needs no hold", Sold, true)
	T:Warns("it said the store has no MemoryStore, once for both calls", "needs a MemoryStore", 1)
end)

Cases.Case("a confirm replayed after its op was compacted away cannot be answered", function(T: Case)
	local Shelf = T:Shelf()

	T:Is("confirming it", (Sell(Shelf, "faded", "faded1", 2)), true)
	T:Is("confirming again while the op is still in the log", (Sell(Shelf, "faded", "faded1", 2)), true)

	Shelf:Log():Compact("faded", Shelf:Format())
	local Late, Why = Sell(Shelf, "faded", "faded1", 2)

	T:Is("confirming again once the op has been folded into the snapshot", Late, false)
	T:Is("the reason, since the record can no longer say whether it took or was turned away", Why, "Unresolved")
	T:Is("the units were still spent exactly once", Shelf:Amount("faded"), 8)
end)

Cases.Case("a transfer of a field moves units and sets them aside in that field on the way", function(T: Case)
	local Shelf = T:Shelf()
	Shelf:Seed("cart", { Stock = 0, Sold = 0, Gold = 0 })

	local Seen: number? = nil
	Shelf:Fault(Fault.Updates():OnKey("cart"):Only(1):Meddle(function()
		Seen = Shelf:Aside("shelf", "Stock")
	end))
	local Ok, Why = Shelf.Store:Transfer("shelf", "cart", 3, "unit1", "Stock"):Wait()
	local Again = Shelf.Store:Transfer("shelf", "cart", 3, "unit1", "Stock"):Wait()

	T:Is("the transfer", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("units set aside in the field while it was on its way", Seen, 3)
	T:Is("the same transfer again", Again, true)
	T:Is("stock left with the sender", Shelf:Amount("shelf"), 7)
	T:Is("stock the receiver got, once", Shelf:Amount("cart"), 3)
	T:Is("nothing left set aside", Shelf:Aside("shelf", "Stock"), 0)
	T:Is("gold, which the transfer never touched", Shelf:Amount("shelf", "Gold"), 0)
end)

Cases.Case("a transfer needs a Field or a Balance, and a field the Default has", function(T: Case)
	local Shelf = T:Shelf()

	T:Throws("a transfer on a store with no Balance and no Field", function()
		Shelf.Store:Transfer("shelf", "cart", 1)
	end)
	T:Throws("a transfer of a field the Default never declared", function()
		Shelf.Store:Transfer("shelf", "cart", 1, nil, "Nonsense")
	end)
	T:Holds("a transfer of a field the Default has", function()
		Shelf.Store:Transfer("shelf", "cart", 1, nil, "Stock"):Wait()
	end)
end)

Cases.Case("a transfer id reused for a different field is refused as spent", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 100, Touches = 10 })
	Bank:Seed("b", { Gold = 0, Touches = 0 })

	T:Is("the transfer of the balance", (Bank.Store:Transfer("a", "b", 5, "same"):Wait()), true)
	local Ok, Why = Bank.Store:Transfer("a", "b", 5, "same", "Touches"):Wait()
	local Named = Bank.Store:Transfer("a", "b", 5, "same", "Gold"):Wait()

	T:Is("the same id on another field", Ok, false)
	T:Is("the reason", Why, "Spent")
	T:Is("the same id naming the balance by hand, which is the same transfer", Named, true)
	T:Is("touches, untouched", Bank:Amount("a", "Touches"), 10)
	T:Is("gold on the receiver, once", Bank:Amount("b"), 5)
end)

Cases.Case("a field transfer a stopped server left is finished by recovery to the right field", function(T: Case)
	local Shelf = T:Shelf()
	Shelf:Write("shelf", {
		Snapshot = { Stock = 7, Sold = 0, Gold = 0, _Held = { unit1 = { To = "cart", Amount = 3, At = T:Now(), Field = "Stock" } } },
		Ops = {},
		Seen = {},
	})
	Shelf:Seed("cart", { Stock = 0, Sold = 0, Gold = 0 })

	T:Is("finishing it", (Shelf.Store:Resettle("shelf"):Wait()), true)
	T:Is("stock the receiver got", Shelf:Amount("cart", "Stock"), 3)
	T:Is("gold the receiver got, none", Shelf:Amount("cart", "Gold"), 0)
	T:Is("nothing left set aside", Shelf:Aside("shelf", "Stock"), 0)
end)

Cases.Case("a field transfer past its window is given back to its field", function(T: Case)
	local Shelf = T:Shelf()
	Shelf:Write("shelf", {
		Snapshot = { Stock = 7, Sold = 0, Gold = 0, _Held = { unit1 = { To = "cart", Amount = 3, At = T:Now() - Windows.REDRIVE - Windows.EXPIRE_MARGIN - 60, Field = "Stock" } } },
		Ops = {},
		Seen = {},
	})

	T:Is("giving it back", (Shelf.Store:Resettle("shelf"):Wait()), true)
	T:Is("stock back with the sender", Shelf:Amount("shelf", "Stock"), 10)
	T:Is("gold, which it never touched", Shelf:Amount("shelf", "Gold"), 0)
	T:Is("nothing left set aside", Shelf:Aside("shelf", "Stock"), 0)
end)

Cases.Case("a purchase is two transfers under two ids, and one that stops between them is finished by running it again", function(T: Case)
	local Shop = T:Store({ Default = Reducers.SHELF, Reducer = Reducers.Shopkeeper, Balance = "Gold", Field = "Stock" })
	Shop:Seed("buyer", { Stock = 0, Sold = 0, Gold = 50 })
	Shop:Seed("shop", { Stock = 10, Sold = 0, Gold = 0 })

	local function Buy(): (boolean, boolean)
		local Paid = Shop.Store:Transfer("buyer", "shop", 20, "order1:price"):Wait()
		local Given = Shop.Store:Transfer("shop", "buyer", 1, "order1:unit", "Stock"):Wait()
		return Paid, Given
	end

	Shop:NoRetries()
	Shop:Fault(Fault.Updates():OnKey("buyer"):Only(3))
	local Paid, Given = Buy()
	Shop:Healed()
	local PaidAgain, GivenAgain = Buy()

	T:Is("the price the first time", Paid, true)
	T:Is("the unit the first time, which stopped on the way", Given, false)
	T:Is("the price again, which had gone through", PaidAgain, true)
	T:Is("the unit again", GivenAgain, true)
	T:Is("gold the shop holds", Shop:Amount("shop", "Gold"), 20)
	T:Is("gold the buyer has left", Shop:Amount("buyer", "Gold"), 30)
	T:Is("stock the buyer holds", Shop:Amount("buyer", "Stock"), 1)
	T:Is("stock the shop has left", Shop:Amount("shop", "Stock"), 9)
	T:Is("nothing set aside on the shop", Shop:Aside("shop", "Stock"), 0)
end)

Cases.Case("a key an older Ledger left a reservation on takes writes and cannot compact, and says so", function(T: Case)
	local Shelf = T:Shelf()
	Shelf:Append("old", { { Id = "bk:cart1", Kind = "__Book", Rid = "cart1", Field = "Stock", Amount = 3, At = T:Now() } :: any })

	T:Is("stock the fold reads, since nothing applies that kind now", Shelf:Amount("old"), 10)
	T:Is("an edit on the key", (Shelf.Store:Edit("old", "Sell", { Count = 2 }):Wait()), true)
	T:Is("stock the edit took", Shelf:Amount("old"), 8)

	Shelf:Log():Compact("old", Shelf:Format())

	T:Is("ops the compaction could not absorb", #Shelf:Record("old").Ops, 2)
	T:Warns("it named the kind it does not apply", "cannot be compacted")
	T:Is("erasing the key, which is the way out", (Shelf.Store:Erase("old"):Wait()), true)
	T:Is("ops left once it is erased", #Shelf:Record("old").Ops, 0)
end)

Cases.Case("a tally counts what was added not what the default holds", function(T: Case)
	local Shelf = T:Store({ Default = { Gold = 100, Free = 0 }, Reducer = Reducers.Shopkeeper })

	local Fresh = Shelf.Store:Total("pot", "Gold"):Wait()
	Shelf.Store:Bump("pot", "Gold", 5):Wait()
	Shelf.Store:Bump("pot", "Gold", 7):Wait()

	T:Is("a tally nobody has added to, on a field that defaults high", Fresh, 0)
	T:Is("the tally after adding twelve", Shelf.Store:Total("pot", "Gold"):Wait(), 12)
	T:Is("a field that defaults to zero still reads the same way", Shelf.Store:Total("pot", "Free"):Wait(), 0)
end)

Cases.Case("a tally sums every shard it is spread over", function(T: Case)
	local Shelf = T:Shelf()

	for _ = 1, 20 do
		Shelf.Store:Bump("pot", "Gold", 5):Wait()
	end

	T:Is("the tally once every shard is summed", Shelf.Store:Total("pot", "Gold"):Wait(), 100)
end)

Cases.Case("a tally cannot be taken from only added to", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Bump("pot", "Gold", 50):Wait()

	T:Throws("taking from a tally", function()
		Shelf.Store:Bump("pot", "Gold", -10):Wait()
	end)
	T:Throws("adding nothing to one", function()
		Shelf.Store:Bump("pot", "Gold", 0):Wait()
	end)
	T:Is("the tally, untouched", Shelf.Store:Total("pot", "Gold"):Wait(), 50)
end)

Cases.Case("tally shards do not collide with ordinary keys", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Edit("pot", "Sell"):Wait()
	Shelf.Store:Bump("pot", "Gold", 25):Wait()

	local Plain = Shelf:State("pot")
	T:Is("the ordinary key of the same name", Plain.Sold, 1)
	T:Is("gold on the ordinary key, which the tally never touched", Plain.Gold, 0)
	T:Is("the tally", Shelf.Store:Total("pot", "Gold"):Wait(), 25)
end)

Cases.Case("many servers bumping a tally do not fight over one key", function(T: Case)
	local Fleet: { any } = {}
	for Index = 1, 12 do
		table.insert(Fleet, T:Shelf(`n{Index}`))
	end

	for _, Shelf in Fleet do
		Shelf.Store:Bump("pot", "Gold", 1):Wait()
	end

	T:Is("the tally after every server added one", Fleet[1].Store:Total("pot", "Gold"):Wait(), 12)
end)

Cases.Case("a compacted tally reads the same on a build that changed the Default", function(T: Case)
	local Wrote = T:Store({ Default = { Gold = 0 }, Reducer = Reducers.Keep, Data = "CaseTallyBase" })
	local Shard = Tally.Shard("pot", Tally.Mine())

	for _ = 1, 20 do
		Wrote.Store:Bump("pot", "Gold", 5):Wait()
	end
	Wrote:Log():Compact(Shard, Wrote:Format())

	local Read = T:Store({ Default = { Gold = 100 }, Reducer = Reducers.Keep, Data = "CaseTallyBase" })

	T:Is("the ops the compaction folded into the snapshot", #Wrote:Record(Shard).Ops, 0)
	T:Is("the tally the build that wrote it reads", Wrote.Store:Total("pot", "Gold"):Wait(), 100)
	T:Is("the tally a build that gives new keys 100 reads", Read.Store:Total("pot", "Gold"):Wait(), 100)
	T:Is("a tally that build has never been bumped", Read.Store:Total("other", "Gold"):Wait(), 0)
end)

Cases.Case("a shard holding a total below zero is caught and not counted", function(T: Case)
	local Shelf = T:Store({ Default = { Gold = 0 }, Reducer = Reducers.Keep, Data = "CaseTallyBent" })
	local Shard = Tally.Shard("bent", Tally.Mine())

	Shelf:Write(Shard, { Snapshot = { Gold = 0, [Shards.FIELD] = { Gold = -50 } }, Ops = {}, Seen = {} })

	T:Is("the total a reader is given, which never goes below zero", Shelf.Store:Total("bent", "Gold"):Wait(), 0)
	T:Is("the shard itself, which is what the reader is protecting against", Shelf:Stored(Shard)._Tally.Gold, -50)
end)

Cases.Case("a bump that carries no Default is counted like any other", function(T: Case)
	local Shelf = T:Store({ Default = { Gold = 0 }, Reducer = Reducers.Keep, Data = "CaseTallyMixed" })
	local Shard = Tally.Shard("pot", Tally.Mine())

	Shelf:Append(Shard, { { Id = "old:1", Kind = "__Bump", Field = "Gold", Amount = 10 } :: any })
	local Alone = Shelf.Store:Total("pot", "Gold"):Wait()

	Shelf.Store:Bump("pot", "Gold", 5):Wait()
	local Moved = Shelf.Store:Total("pot", "Gold"):Wait()

	Shelf:Append(Shard, { { Id = "old:2", Kind = "__Bump", Field = "Gold", Amount = 7 } :: any })
	T:Advance(Suite.Horizons.TALLY_KEEP + 1)

	T:Is("a bump that names no Default, read on its own", Alone, 10)
	T:Is("the tally once another bump lands on it", Moved, 15)
	T:Is("a third bump landing after those two, once every kept sum has run out", Shelf.Store:Total("pot", "Gold"):Wait(), 22)
end)

Cases.Case("a bump landing while the shards are read is counted once", function(T: Case)
	local Vault = T:Vault("nodeA")
	local Mine = Tally.Mine(Vault.Store.Node)
	T:Ok("this server's shard is not the first one read, so a bump can land ahead of it", Mine > 0)
	T:Ok("the first bump", (Vault.Store:Bump("pot", "Coins", 5):Wait()))
	T:Advance(1)

	local Landed = false
	Vault:Fault(Fault.Reads():OnKey(Tally.Shard("pot", Mine - 1)):Only(1):Meddle(function()
		Landed = Vault.Store:Bump("pot", "Coins", 100):Wait()
	end))
	local Sum = Vault.Store:Total("pot", "Coins"):Wait()

	T:Ok("the bump that landed while the shards were being read", Landed)
	T:Is("the total, which cannot hold that bump twice", Sum, 105)
end)

Cases.Case("a fleet spreads its bumps over more than one shard", function(T: Case)
	local Fleet: { any } = {}
	for Index = 1, 12 do
		table.insert(Fleet, T:Shelf(`spread{Index}`))
	end
	for _, Held in Fleet do
		Held.Store:Bump("spread", "Gold", 1):Wait()
	end

	local Written = 0
	for _, Key in Tally.Keys("spread") do
		if (Fleet[1].Direct:Current(Key)) ~= nil then
			Written += 1
		end
	end

	T:Is("the tally every server added to", (Fleet[1].Store:Total("spread", "Gold"):Wait()), 12)
	T:Is("shard keys they actually wrote, which is the whole point of spreading it", Written > 1, true)
	T:Is("and never more keys than there are shards", Written <= Shards.SHARDS, true)
end)

Cases.Case("a total refuses rather than under reporting when a shard cannot be read", function(T: Case)
	local Shelf = T:Shelf()
	for Index = 1, 6 do
		T:Shelf(`part{Index}`).Store:Bump("part", "Gold", 5):Wait()
	end

	T:Is("the total while every shard is readable", (Shelf.Store:Total("part", "Gold"):Wait()), 30)

	T:Advance(Suite.Horizons.TALLY_KEEP + 1)
	Shelf:Fault(Fault.Reads():OnKey(Tally.Shard("part", 0)))
	Shelf:NoRetries()
	local Sum, Why = Shelf.Store:Total("part", "Gold"):Wait()

	T:Is("the total with one shard unreadable", Sum, nil)
	T:Is("the reason, since a number would be wrong rather than late", Why, "Unresolved")
end)

Cases.Case("a reducer that writes Ledger's own bookkeeping has every field of it put back", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("meddler", { Gold = 50, Touches = 0 })

	local Ok = Bank.Store:Edit("meddler", "Meddle"):Wait()

	T:Is("the edit still goes through", Ok, true)
	T:Is("what the reducer was allowed to change", Bank:State("meddler").Touches, 1)
	T:Is("the gold it left alone", Bank:State("meddler").Gold, 50)
	T:Accuses("it put the money set aside back", "wrote its own _Held")
	T:Accuses("it put the applied names back", "wrote its own _Received")
	T:Accuses("it put the tally back", "wrote its own _Tally")
end)

return Cases
