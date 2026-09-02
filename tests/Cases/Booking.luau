--!strict
--!optimize 2

--[=[

	Booking: One rule per case for the units that cross keys, the old booking layer, and tallies.

	Units cross keys with Transfer and a Field now, so the transfer cases for a field are here, and a
	confirm is the game's own op whether or not a hold stands behind it. A booking the old layer still
	holds is confirmed, released, handed over and given back the old way until it is gone, and those
	cases plant one. The tally cases are the other half. The hold cases are in Holds, since a hold
	needs a MemoryStore and these do not.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau booking
--]=]

local Suite = require("../Suite")

local Ledger = require("../../src") :: any
local Engine = require("../../src/Util/Engine")
local Windows = require("../../src/Core/Constants/Windows")
local Booking = require("../../src/Layers/Booking")
local Shards = require("../../src/Core/Constants/Shards")
local Tally = require("../../src/Layers/Tally")

local Fault = Suite.Fault
local Reducers = Suite.Reducers

type Case = Suite.Case
type Fixture = Suite.Fixture

local STALE = Windows.BOOK + Windows.BOOK_MARGIN + 60

local Cases = Suite.File("Booking")

local function Counted(Booked: any): number
	local Total = 0
	for Rid in Booked do
		if Booking.Entry(Booked, Rid) ~= nil then
			Total += 1
		end
	end
	return Total
end

local function Spoiling(State: any, Op: any): any?
	if Op.Kind ~= "Spoil" then
		return nil
	end

	local Next = table.clone(State)
	Next.Stock = "many"
	return Next
end

local function Sell(Shelf: Fixture, Key: string, Rid: string, Count: number): (boolean, any)
	return Shelf.Store:Confirm(Key, Rid, "Sell", { Count = Count }):Wait()
end

local function Planted(T: Case, Key: string, Booked: { [string]: any }, Stock: number?): Fixture
	local Shelf = T:Shelf()
	Shelf:Write(Key, { Snapshot = { Stock = Stock or 10, Sold = 0, Gold = 0, _Booked = Booked }, Ops = {}, Seen = {} })
	return Shelf
end

local function Old(T: Case, Amount: number, To: string?, Handing: boolean?): { [string]: any }
	return { Field = "Stock", Amount = Amount, At = T:Now(), To = To, Handing = Handing }
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

Cases.Case("an old booking still on the key is confirmed and released the old way", function(T: Case)
	local Shelf = Planted(T, "shelf", { old1 = Old(T, 1), old2 = Old(T, 1) }, 8)

	T:Is("confirming an old booking", (Sell(Shelf, "shelf", "old1", 1)), true)
	local Now = Shelf:State("shelf")
	T:Is("stock, which the old booking had already taken", Now.Stock, 8)
	T:Is("what the reducer counted, nothing, since the old booking was the spend", Now.Sold, 0)
	T:Is("releasing the other", (Shelf.Store:Release("shelf", "old2"):Wait()), true)
	T:Is("stock once it came back", Shelf:Amount("shelf"), 9)
	T:Is("old bookings left", Shelf:Booked("shelf"), 0)
end)

Cases.Case("a reducer cannot write its own bookings", function(T: Case)
	local Shelf = T:Store({
		Default = Reducers.SHELF,
		Field = "Stock",
		Reducer = function(State: any, Op: any): any?
			if Op.Kind ~= "Meddle" then
				return nil
			end
			local Next = table.clone(State)
			Next._Booked = { forged = { Field = "Stock", Amount = 99, At = 0 } }
			return Next
		end,
	})
	Shelf:Write("shelf", { Snapshot = { Stock = 8, Sold = 0, Gold = 0, _Booked = { cart1 = Old(T, 2) } }, Ops = {}, Seen = {} })

	Shelf.Store:Edit("shelf", "Meddle"):Wait()
	local Now = Shelf:State("shelf")

	T:Accuses("it named itself for a mistake the reducer made", "your reducer wrote its own _Booked")
	T:Is("the forged booking", Now._Booked["forged"], nil)
	T:Is("the real one", Now._Booked["cart1"].Amount, 2)
	T:Is("stock left", Now.Stock, 8)
end)

Cases.Case("an old booking nobody takes is given back by the sweep", function(T: Case)
	local Shelf = Planted(T, "shelf", { walkedaway = Old(T, 6) }, 4)
	Shelf.Store:Peek("shelf"):Wait()
	local Stranded = Shelf:Amount("shelf")

	T:Advance(STALE)
	T:Sweep()

	T:Is("stock while the old booking is held", Stranded, 4)
	T:Is("stock once the sweep gives it back", Shelf:Amount("shelf"), 10)
	T:Is("old bookings left", Shelf:Booked("shelf"), 0)
end)

Cases.Case("an expired old booking is kept when the field cannot take it back", function(T: Case)
	local Shelf = T:Store({ Default = { Stock = 10, Other = 5 }, Reducer = Spoiling, Field = "Stock" })
	Shelf:Write("shelf", { Snapshot = { Stock = 6, Other = 5, _Booked = { held1 = { Field = "Stock", Amount = 4, At = T:Now() } } }, Ops = {}, Seen = {} })

	Shelf.Store:Edit("shelf", "Spoil"):Wait()
	T:Advance(STALE)
	Shelf.Store:Resettle("shelf"):Wait()
	local Now = Shelf:State("shelf")

	T:Is("the booking whose field can no longer take it back", Now._Booked["held1"].Amount, 4)
	T:Is("old bookings held", Counted(Now._Booked), 1)
end)

Cases.Case("a grant moves an old booking's units to the other key exactly once", function(T: Case)
	local Shelf = Planted(T, "shelf", { move1 = Old(T, 3, "cart") }, 7)

	local Ok = Shelf.Store:Grant("shelf", "move1"):Wait()
	local Again = Shelf.Store:Grant("shelf", "move1"):Wait()

	T:Is("handing it over", Ok, true)
	T:Is("handing the same one over again", Again, false)
	T:Is("stock left with the sender", Shelf:Amount("shelf"), 7)
	T:Is("stock the receiver got", Shelf:Amount("cart"), 13)
	T:Is("old bookings left", Shelf:Booked("shelf"), 0)
	T:Is("stock is conserved", Shelf:Amount("shelf") + Shelf:Amount("cart"), 20)
end)

Cases.Case("confirming an old booking that was handed over is refused", function(T: Case)
	local Shelf = Planted(T, "shelf", { move1 = Old(T, 3, "cart") }, 7)

	local Gave = Shelf.Store:Grant("shelf", "move1"):Wait()
	local Took, Why = Sell(Shelf, "shelf", "move1", 3)

	T:Is("handing it over", Gave, true)
	T:Is("confirming units that went to another key, which is the game's op on what is left", Took, true)
	T:Is("the reason", Why, nil)
	T:Is("stock left with the sender, the confirm having sold from it", Shelf:Amount("shelf"), 4)
	T:Is("stock the receiver got", Shelf:Amount("cart"), 13)
end)

Cases.Case("an old booking spent before the hand over marks it hands nothing over", function(T: Case)
	local Shelf = Planted(T, "shelf", { move1 = Old(T, 3, "cart") }, 7)
	local Held = assert(Booking.Entry(Shelf:Stored("shelf")._Booked, "move1"), "the booking was not planted")

	Sell(Shelf, "shelf", "move1", 3)
	local Gave = Shelf.Store:Handed("shelf", "move1", Held)

	T:Is("handing over a booking that was confirmed first", Gave, false)
	T:Is("stock the receiver never got", Shelf:Amount("cart"), 10)
	T:Is("stock left with the sender", Shelf:Amount("shelf"), 7)
	T:Is("old bookings left", Shelf:Booked("shelf"), 0)
end)

Cases.Case("an old booking given back before the hand over marks it hands nothing over", function(T: Case)
	local Shelf = Planted(T, "shelf", { move1 = Old(T, 3, "cart") }, 7)
	local Held = assert(Booking.Entry(Shelf:Stored("shelf")._Booked, "move1"), "the booking was not planted")

	Shelf.Store:Release("shelf", "move1"):Wait()
	local Gave = Shelf.Store:Handed("shelf", "move1", Held)

	T:Is("handing over a booking that was released first", Gave, false)
	T:Is("stock the receiver never got", Shelf:Amount("cart"), 10)
	T:Is("stock given back to the sender", Shelf:Amount("shelf"), 10)
end)

Cases.Case("a grant racing a confirm on an old booking leaves the units in exactly one place", function(T: Case)
	local Shelf = Planted(T, "shelf", { move1 = Old(T, 3, "cart") }, 7)

	local Gave, Took = false, false
	T:Race({
		function()
			Gave = (Shelf.Store:Grant("shelf", "move1"):Wait())
		end,
		function()
			Took = (Sell(Shelf, "shelf", "move1", 3))
		end,
	})

	local Delivered = Booking.Delivered(Shelf:Stored("cart"), "move1")
	local Places = (if Shelf:Amount("shelf") == 10 then 1 else 0) + (if Delivered then 1 else 0) + (if Took then 1 else 0)

	T:Is("how many places the units ended up in", Places, 1)
	T:Is("how many callers were told they got them", (if Gave then 1 else 0) + (if Took then 1 else 0), 1)
	T:Is("the receiver holds them only if the grant said so", Delivered, Gave)
	T:Is("old bookings left", Shelf:Booked("shelf"), 0)
end)

Cases.Case("a grant that dies after delivering is finished not given back", function(T: Case)
	local Shelf = Planted(T, "shelf", { half1 = Old(T, 4, "cart") }, 6)

	Shelf:Fault(Fault.Updates():After(2))
	Shelf.Store:Grant("shelf", "half1"):Wait()
	Shelf:Healed()

	T:Is("the receiver already has it", Shelf:Amount("cart"), 14)
	T:Is("the sender is still holding it", Shelf:Booked("shelf"), 1)

	T:Advance(STALE)
	Shelf.Store:Peek("shelf"):Wait()
	T:Sweep()

	T:Is("stock left with the sender, not given back", Shelf:Amount("shelf"), 6)
	T:Is("stock the receiver keeps", Shelf:Amount("cart"), 14)
	T:Is("old bookings left", Shelf:Booked("shelf"), 0)
end)

Cases.Case("a grant that never delivered is given back", function(T: Case)
	local Shelf = Planted(T, "shelf", { never1 = Old(T, 4, "cart") }, 6)

	T:Advance(STALE)
	Shelf.Store:Peek("shelf"):Wait()
	T:Sweep()

	T:Is("stock given back to the sender", Shelf:Amount("shelf"), 10)
	T:Is("stock the receiver never got", Shelf:Amount("cart"), 10)
	T:Is("old bookings left", Shelf:Booked("shelf"), 0)
end)

Cases.Case("a grant into an erased key keeps the units with the sender", function(T: Case)
	local Shelf = Planted(T, "shelf", { tomb1 = Old(T, 5, "cart") }, 5)
	Shelf.Store:Edit("cart", "Sell"):Wait()
	Shelf.Store:Erase("cart"):Wait()

	local Ok, Why = Shelf.Store:Grant("shelf", "tomb1"):Wait()

	T:Is("handing it into an erased key", Ok, false)
	T:Is("the reason, since the units left the sender", Why, "Held")
	T:Is("the units, still set aside", Shelf:Booked("shelf"), 1)
	T:Is("stock the receiver did not get", Shelf:Amount("cart"), 10)
end)

Cases.Case("a grant the receiver would not take keeps the units", function(T: Case)
	local Shelf = T:Store({ Default = { Stock = 10 }, Reducer = Spoiling, Field = "Stock" })
	Shelf:Write("shelf", { Snapshot = { Stock = 6, _Booked = { bad1 = Old(T, 4, "cart") } }, Ops = {}, Seen = {} })
	Shelf.Store:Edit("cart", "Spoil"):Wait()

	local Ok, Why = Shelf.Store:Grant("shelf", "bad1"):Wait()

	T:Is("handing units to a key that will not take them", Ok, false)
	T:Is("the reason, since the units left the sender", Why, "Held")
	T:Is("stock the sender still has", Shelf:Amount("shelf"), 6)
	T:Is("the units, still set aside rather than gone", Shelf:Booked("shelf"), 1)

	local Gave, Refused = Shelf.Store:Release("shelf", "bad1"):Wait()
	T:Is("giving them back by hand", Gave, false)
	T:Is("the reason", Refused, "Held")
	T:Warns("it said recovery owns it", "is being handed to another key")

	T:Advance(STALE)
	T:Sweep()
	T:Is("stock once recovery has given them back", Shelf:Amount("shelf"), 10)
	T:Is("old bookings left", Shelf:Booked("shelf"), 0)
end)

Cases.Case("an old booking with no destination cannot be granted", function(T: Case)
	local Shelf = Planted(T, "shelf", { plain1 = Old(T, 2) }, 8)

	local Ok = Shelf.Store:Grant("shelf", "plain1"):Wait()

	T:Is("handing over a booking that names nowhere", Ok, false)
	T:Is("the units, still set aside", Shelf:Booked("shelf"), 1)
	T:Is("confirming it instead", (Sell(Shelf, "shelf", "plain1", 2)), true)
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
	T:Advance(Suite.Horizons.TALLY_CACHE + 1)

	T:Is("a bump that names no Default, read on its own", Alone, 10)
	T:Is("the tally once another bump lands on it", Moved, 15)
	T:Is("a third bump landing after those two, once the cached sum has run out", Shelf.Store:Total("pot", "Gold"):Wait(), 22)
end)

Cases.Case("a reset says which old bookings it destroyed", function(T: Case)
	local Shelf = Planted(T, "shelf", { cart1 = Old(T, 3) }, 7)

	local Before = Shelf:Booked("shelf")
	local Reset = Shelf.Store:Reset("shelf"):Wait()

	T:Is("the old booking before the reset", Before, 1)
	T:Is("the reset, which a plain booking does not stand in the way of", Reset, true)
	T:Is("what is set aside afterwards", Shelf:Booked("shelf"), 0)
	T:Is("releasing the id the caller is still holding", (Shelf.Store:Release("shelf", "cart1"):Wait()), false)
	T:Warns("it said the reservations went with it", "Confirm and Release on those ids are refused", 1)
end)

Cases.Case("a reset is refused while an old booking owes units to another key", function(T: Case)
	local Shelf = Planted(T, "shelf", { cart1 = Old(T, 3, "buyer") }, 7)

	local Ok, Why = Shelf.Store:Reset("shelf"):Wait()

	T:Is("the reset", Ok, false)
	T:Is("the reason", Why, "Busy")
	T:Is("the booking it would have dropped", Shelf:Booked("shelf"), 1)
end)

Cases.Case("a reset cannot leave granted units on both keys", function(T: Case)
	local Shelf = Planted(T, "shelf", { cart1 = Old(T, 3, "buyer") }, 7)
	local Before = Shelf:Amount("shelf") + Shelf:Amount("buyer") + 3

	local Held = assert(Booking.Entry(Shelf:Stored("shelf")._Booked, "cart1"), "the booking was not planted")
	Shelf:Append("buyer", { Booking.Give("cart1", Held.Field, Held.Amount, Booking.Terms("shelf", "cart1", Held)) })

	local Reset = Shelf.Store:Reset("shelf"):Wait()
	Shelf:Append("shelf", { Booking.Take("cart1") })

	T:Is("a reset in the middle of a hand over", Reset, false)
	T:Is("stock across both keys", Shelf:Amount("shelf") + Shelf:Amount("buyer"), Before)
end)

local function Stranded(T: Case, Count: number, To: string?, Handing: boolean?): any
	local Booked: { [string]: any } = {}
	for Index = 1, Count do
		Booked[`old{Index}`] = Old(T, 1, To, Handing)
	end
	return Planted(T, "shelf", Booked)
end

Cases.Case("more overdue reservations than one pass takes are left for the next", function(T: Case)
	local Shelf = Stranded(T, 40, nil)
	T:Advance(STALE)

	Shelf.Store:Resettle("shelf"):Wait()

	T:Warns("it said it left some behind", "overdue reservations")
	T:Is("reservations it could not get to this pass", Shelf:Booked("shelf") > 0, true)
end)

Cases.Case("a reservation whose receiver cannot be read waits for the next pass", function(T: Case)
	local Shelf = Stranded(T, 1, "cart")
	T:Advance(STALE)

	Shelf:NoRetries()
	Shelf:Fault(Fault.Reads():OnKey("cart"))
	Shelf.Store:Resettle("shelf"):Wait()
	Shelf:Healed()

	T:Warns("it said it could not check the receiver", "before giving back booking")
	T:Is("the reservation is still held", Shelf:Booked("shelf"), 1)
end)

Cases.Case("a hand over that started is written off past the prune horizon", function(T: Case)
	local Shelf = Stranded(T, 1, "cart", true)
	T:Advance(31 * 86400)

	Shelf.Store:Resettle("shelf"):Wait()

	T:Warns("it said giving it back could pay twice", "giving it back could pay twice")
	T:Is("the reservation is gone", Shelf:Booked("shelf"), 0)
	T:Is("the units were not given back", Shelf:Amount("shelf"), 10)
end)

Cases.Case("a reservation that never started a hand over is given back past the prune horizon", function(T: Case)
	local Shelf = Stranded(T, 1, "cart")
	T:Advance(31 * 86400)

	Shelf.Store:Resettle("shelf"):Wait()

	T:Is("the reservation is gone", Shelf:Booked("shelf"), 0)
	T:Is("the units came back", Shelf:Amount("shelf"), 11)
end)

Cases.Case("a hand over that reaches the receiver past the grace is turned away", function(T: Case)
	local Shelf = Planted(T, "shelf", { cart1 = Old(T, 3, "buyer") }, 7)

	local Held = assert(Booking.Entry(Shelf:Stored("shelf")._Booked, "cart1"), "the booking was not planted")
	local Stale = table.clone(Held)
	Stale.At = Held.At - (Windows.BOOK + Windows.BOOK_MARGIN + 60)

	T:Throws("a hand over landing after recovery may act", function()
		Shelf.Store:Handed("shelf", "cart1", Stale)
	end)

	T:Is("the receiver holds no grant", Booking.Delivered(Shelf:State("buyer"), "cart1"), false)
	T:Is("the units are still set aside", Shelf:Booked("shelf"), 1)
end)

Cases.Case("a hand over onto units the key already gave back accuses itself", function(T: Case)
	local Shelf = T:Shelf()
	Shelf:Append("shelf", { Booking.Undo("cart1") })
	Shelf:Append("shelf", { Booking.Book("cart1", "Stock", 3, nil, "buyer") })

	local Ok, Why = Shelf.Store:Grant("shelf", "cart1"):Wait()

	T:Accuses("it noticed the units had been given back", "had already given the same units back")
	T:Is("the hand over", Ok, false)
	T:Is("the reason", Why, "Unresolved")
end)

Cases.Case("a reservation Ledger cannot read is named in a warning", function(T: Case)
	local Shelf = T:Shelf()
	Shelf:Write("shelf", {
		Snapshot = { Stock = 10, Sold = 0, Gold = 0, _Booked = { torn = { Field = "Stock", Amount = "gone" } } },
		Ops = {},
		Seen = {},
	})

	Shelf.Store:Resettle("shelf"):Wait()

	T:Warns("it named the reservation", "that Ledger cannot read")
	T:Is("nothing cleared it", Shelf:State("shelf")._Booked.torn ~= nil, true)
end)

Cases.Case("overdue reservations that cannot be settled wait for the next pass", function(T: Case)
	local Shelf = Stranded(T, 2, nil)
	T:Advance(STALE)

	Shelf:NoRetries()
	Shelf:Fault(Fault.Updates():OnKey("shelf"))
	Shelf.Store:Resettle("shelf"):Wait()
	Shelf:Healed()

	T:Warns("it said they wait for the next pass", "overdue reservation(s) on")
	T:Is("the reservations are still held", Shelf:Booked("shelf"), 2)
end)

Cases.Case("an erase hands over the units an old booking owes another key", function(T: Case)
	local Shelf = Planted(T, "shelf", { move1 = Old(T, 3, "cart") }, 7)

	T:Is("stock left on the shelf with the old booking on it", Shelf:Amount("shelf"), 7)
	T:Is("erasing the key the units are owed by", Shelf.Store:Erase("shelf"):Wait(), true)

	T:Is("stock the receiver got", Shelf:Amount("cart"), 13)
	T:Is("old bookings left", Shelf:Booked("shelf"), 0)
	T:Silent("nothing was destroyed on the way out", "destroyed 1 reservation")
end)

Cases.Case("an erase cannot hand over units the receiver will not take", function(T: Case)
	local Shelf = Planted(T, "shelf", { move1 = Old(T, 3, "cart") }, 7)
	Shelf.Store:Erase("cart"):Wait()

	T:Is("erasing the key the units are owed by", Shelf.Store:Erase("shelf"):Wait(), true)

	T:Is("stock the erased receiver got", Shelf:Amount("cart"), 10)
	T:Warns("it named the booking it could not hand over", "could not hand booking 'move1'")
	T:Warns("it named what went with the key", "destroyed 1 reservation(s) holding 3 Stock")
end)

Cases.Case("an erase leaves an old booking that is owed to nobody alone", function(T: Case)
	local Shelf = Planted(T, "shelf", { keep1 = Old(T, 3) }, 7)

	T:Is("erasing the key holding it", Shelf.Store:Erase("shelf"):Wait(), true)

	T:Warns("it named what went with the key", "destroyed 1 reservation(s) holding 3 Stock")
end)

Cases.Case("giving back a booking that would take units away accuses Ledger instead", function(T: Case)
	local Shelf = T:Shelf()
	Shelf:Seed("bent", { Stock = 10, Sold = 0, Gold = 0, _Booked = { bent1 = { Field = "Stock", Amount = -5, At = T:Now() } } })

	local Ok = Shelf.Store:Release("bent", "bent1"):Wait()

	T:Is("releasing a booking whose amount would shrink the field", Ok, false)
	T:Is("the stock it would have taken from", Shelf:State("bent").Stock, 10)
	T:Is("the booking is left where it was", Shelf:Booked("bent"), 1)
	T:Accuses("it named itself rather than shrinking the field", "left less of")
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
	T:Accuses("it put the units set aside back", "wrote its own _Booked")
	T:Accuses("it put the tally back", "wrote its own _Tally")
end)

Cases.Case("two servers granting one old booking hand the units over once", function(T: Case)
	local One, Two = T:Shelf("nodeA"), T:Shelf("nodeB")
	One:Write("twinshelf", { Snapshot = { Stock = 7, Sold = 0, Gold = 0, _Booked = { twin1 = Old(T, 3, "twincart") } }, Ops = {}, Seen = {} })
	One:Seed("twincart", { Stock = 0, Sold = 0, Gold = 0 })

	local First, Second: any = nil, nil
	T:Race({
		function()
			First = (One.Store:Grant("twinshelf", "twin1"):Wait())
		end,
		function()
			Second = (Two.Store:Grant("twinshelf", "twin1"):Wait())
		end,
	})

	T:Is("the units the receiver holds", One:Amount("twincart"), 3)
	T:Is("the units left on the shelf", One:Amount("twinshelf"), 7)
	T:Is("the units add up", One:Amount("twinshelf") + One:Amount("twincart"), 10)
	T:Is("nothing is still set aside", One:Booked("twinshelf"), 0)
	T:Is("at least one server was told it went through", First == true or Second == true, true)
end)

Cases.Case("an old booking past its hold is still spent by a confirm that gets there first", function(T: Case)
	local Shelf = Planted(T, "holdA", { holdA1 = Old(T, 3) }, 7)
	T:Advance(STALE)

	T:Is("confirming it once its hold has run out", (Sell(Shelf, "holdA", "holdA1", 3)), true)
	T:Is("the stock it spent, which was already set aside", Shelf:Amount("holdA"), 7)
	T:Is("nothing is left set aside", Shelf:Booked("holdA"), 0)
end)

Cases.Case("a hand over past its hold is refused where a confirm would not be", function(T: Case)
	local Shelf = Planted(T, "holdC", { holdC1 = Old(T, 3, "holdCart") }, 7)
	T:Advance(STALE)

	local Ok, Why = Shelf.Store:Grant("holdC", "holdC1"):Wait()

	T:Is("handing it over once its hold has run out", Ok, false)
	T:Is("the reason", Why, "Spent")
	T:Is("the units are left set aside for recovery", Shelf:Booked("holdC"), 1)
	T:Is("and the receiver was given nothing", Shelf:Amount("holdCart"), 10)
end)

Cases.Case("an old booking can still be released after it has been compacted into the snapshot", function(T: Case)
	local Shelf = Planted(T, "packed", { packed1 = Old(T, 3) }, 7)
	Shelf.Store:Edit("packed", "Sell"):Wait()
	Shelf:Log():Compact("packed", Shelf:Format())

	T:Is("ops left after compaction", #Shelf:Record("packed").Ops, 0)
	T:Is("the booking, living in the snapshot", Shelf:Booked("packed"), 1)
	T:Is("releasing it from there", (Shelf.Store:Release("packed", "packed1"):Wait()), true)
	T:Is("the units it gave back", Shelf:Amount("packed"), 9)
	T:Is("nothing is left set aside", Shelf:Booked("packed"), 0)
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

	T:Advance(Suite.Horizons.TALLY_CACHE + 1)
	Shelf:Fault(Fault.Reads():OnKey(Tally.Shard("part", 0)))
	Shelf:NoRetries()
	local Sum, Why = Shelf.Store:Total("part", "Gold"):Wait()

	T:Is("the total with one shard unreadable", Sum, nil)
	T:Is("the reason, since a number would be wrong rather than late", Why, "Unresolved")
end)

Cases.Case("a grant whose old booking another server gave back hands nothing over", function(T: Case)
	local One, Two = T:Shelf("granta"), T:Shelf("grantb")
	One:Write("gsrc", { Snapshot = { Stock = 7, Sold = 0, Gold = 0, _Booked = { gswap1 = Old(T, 3, "gdst") } }, Ops = {}, Seen = {} })
	One:Seed("gdst", { Stock = 0, Sold = 0, Gold = 0 })
	One:Fault(Fault.Updates():OnKey("gsrc"):Only(1):Stall(5))

	local Ok, Why: any = nil, nil
	T:Race({
		function()
			Ok, Why = One.Store:Grant("gsrc", "gswap1"):Wait()
		end,
		function()
			Two.Store:Release("gsrc", "gswap1"):Wait()
		end,
	})

	T:Is("the grant, once the booking went from under it", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("the units went back to the key that held them", One:Amount("gsrc"), 10)
	T:Is("and none of them reached the receiver", One:Amount("gdst"), 0)
	T:Is("nothing is left set aside", One:Booked("gsrc"), 0)
end)

return Cases
