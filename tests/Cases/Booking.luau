--!strict
--!optimize 2

--[=[

	Booking: One rule per case for units set aside on a single key, and for tallies.

	Reserving units under a name, confirming them, releasing them, letting a hold run out, and handing
	a booking to another key. The tally cases are the other half: a total spread over its own keys and
	only ever added to.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau
--]=]

local Suite = require("../Suite")

local Windows = require("../../src/Core/Constants/Windows")
local Sizes = require("../../src/Core/Constants/Sizes")
local Booking = require("../../src/Layers/Booking")
local Kinds = require("../../src/Core/Constants/Kinds")
local Shards = require("../../src/Core/Constants/Shards")
local Tally = require("../../src/Layers/Tally")

local function Counted(Booked: any): number
	local Total = 0
	for Rid in Booked do
		if Booking.Entry(Booked, Rid) ~= nil then
			Total += 1
		end
	end
	return Total
end

local Fault = Suite.Fault
local Reducers = Suite.Reducers
local Reasons = Suite.Reasons

type Case = Suite.Case

local STALE = Windows.BOOK + Windows.BOOK_MARGIN + 60

local Cases = Suite.File("Booking")

local function Spoiling(State: any, Op: any): any?
	if Op.Kind ~= "Spoil" then
		return nil
	end

	local Next = table.clone(State)
	Next.Stock = "many"
	return Next
end

Cases.Case("a reservation sets units aside without spending them", function(T: Case)
	local Shelf = T:Shelf()

	local Ok, Why = Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()
	local Now = Shelf:State("shelf")

	T:Is("the reservation", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("stock left on the shelf", Now.Stock, 7)
	T:Is("units held under the booking", Now._Booked["cart1"].Amount, 3)
	T:Is("the field it was taken from", Now._Booked["cart1"].Field, "Stock")
	T:Is("stock plus what is set aside", Now.Stock + Now._Booked["cart1"].Amount, 10)
end)

Cases.Case("confirming a booking spends the units for good", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()
	local Ok = Shelf.Store:Confirm("shelf", "cart1"):Wait()

	T:Is("confirming the booking", Ok, true)
	T:Is("stock left once it is confirmed", Shelf:Amount("shelf"), 7)
	T:Is("anything still set aside", Shelf:Booked("shelf"), 0)
end)

Cases.Case("releasing a booking puts the units back", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 4, "cart1"):Wait()
	local Ok = Shelf.Store:Release("shelf", "cart1"):Wait()

	T:Is("releasing the booking", Ok, true)
	T:Is("stock once the units are given back", Shelf:Amount("shelf"), 10)
	T:Is("anything still set aside", Shelf:Booked("shelf"), 0)
end)

Cases.Case("more cannot be set aside than the field holds", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 8, "cart1"):Wait()
	local Ok, Why = Shelf.Store:Reserve("shelf", "Stock", 5, "cart2"):Wait()

	T:Is("a reservation the shelf cannot cover", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("stock left on the shelf", Shelf:Amount("shelf"), 2)
	T:Is("bookings held", Shelf:Booked("shelf"), 1)
	T:Silent("it refused cleanly rather than tripping a guard", "a bug in Ledger")
end)

Cases.Case("ten buyers take ten units and the eleventh is turned away", function(T: Case)
	local Shelf = T:Shelf()

	local Taken = 0
	for Index = 1, 11 do
		if Shelf.Store:Reserve("shelf", "Stock", 1, `buyer{Index}`):Wait() then
			Taken += 1
			Shelf.Store:Confirm("shelf", `buyer{Index}`):Wait()
		end
	end

	T:Is("buyers who got one", Taken, 10)
	T:Is("stock left", Shelf:Amount("shelf"), 0)
	T:Is("anything still set aside", Shelf:Booked("shelf"), 0)
end)

Cases.Case("asking again under the same name does not set aside twice", function(T: Case)
	local Shelf = T:Shelf()

	local First = Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()
	local Again = Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()

	T:Is("the first reservation", First, true)
	T:Is("asking again under the same name", Again, true)
	T:Is("stock left, having been set aside once", Shelf:Amount("shelf"), 7)
	T:Is("bookings held", Shelf:Booked("shelf"), 1)
end)

Cases.Case("confirming twice only spends once", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 2, "cart1"):Wait()
	local First = Shelf.Store:Confirm("shelf", "cart1"):Wait()
	local Again = Shelf.Store:Confirm("shelf", "cart1"):Wait()

	T:Is("confirming it", First, true)
	T:Is("confirming the same booking again", Again, true)
	T:Is("stock left", Shelf:Amount("shelf"), 8)
	T:Is("anything still set aside", Shelf:Booked("shelf"), 0)
end)

Cases.Case("confirming after a release cannot spend the units again", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 2, "cart1"):Wait()
	Shelf.Store:Release("shelf", "cart1"):Wait()
	local Late = Shelf.Store:Confirm("shelf", "cart1"):Wait()

	T:Is("confirming a booking that was already given back", Late, false)
	T:Is("stock, which stays whole", Shelf:Amount("shelf"), 10)
	T:Is("anything still set aside", Shelf:Booked("shelf"), 0)
end)

Cases.Case("a booking nobody takes is given back by the next one", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 6, "abandoned"):Wait()
	local Stranded = Shelf:Amount("shelf")

	T:Advance(STALE)
	local Later = Shelf.Store:Reserve("shelf", "Stock", 6, "fresh"):Wait()
	local Now = Shelf:State("shelf")

	T:Is("stock while the abandoned booking is held", Stranded, 4)
	T:Is("a later booking the shelf could not cover until then", Later, true)
	T:Is("stock once the stale one is given back", Now.Stock, 4)
	T:Is("bookings held, the stale one having gone", Counted(Now._Booked), 1)
	T:Is("the one that is left", Now._Booked["fresh"] ~= nil, true)
end)

Cases.Case("an expired booking is kept when the field cannot take it back", function(T: Case)
	local Shelf = T:Store({ Default = { Stock = 10, Other = 5 }, Reducer = Spoiling, Field = "Stock" })

	Shelf.Store:Reserve("shelf", "Stock", 4, "held1"):Wait()
	Shelf.Store:Edit("shelf", "Spoil"):Wait()
	T:Advance(STALE)

	-- another reservation on a field that still works, which runs the sweep
	Shelf.Store:Reserve("shelf", "Other", 1, "held2"):Wait()
	local Now = Shelf:State("shelf")

	T:Is("the booking whose field can no longer take it back", Now._Booked["held1"].Amount, 4)
	T:Is("bookings held", Counted(Now._Booked), 2)
	T:Is("the field that still works", Now.Other, 4)
end)

Cases.Case("a fresh booking is not swept by another", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 3, "first"):Wait()
	Shelf.Store:Reserve("shelf", "Stock", 3, "second"):Wait()

	T:Is("stock left with both held", Shelf:Amount("shelf"), 4)
	T:Is("bookings held", Shelf:Booked("shelf"), 2)
end)

Cases.Case("a booking survives compaction and a reload", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()
	for _ = 1, 40 do
		Shelf.Store:Edit("shelf", "Sell"):Wait()
	end

	Shelf:Log():Compact("shelf", Shelf:Format())
	local Now = Shelf:State("shelf")

	T:Is("ops left after compaction", #Shelf:Record("shelf").Ops, 0)
	T:Is("the booking, once it lives in the snapshot", Now._Booked["cart1"].Amount, 3)
	T:Is("stock left", Now.Stock, 7)
	T:Is("confirming it after a compaction", Shelf.Store:Confirm("shelf", "cart1"):Wait(), true)
	T:Is("stock once confirmed", Shelf:Amount("shelf"), 7)
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

	Shelf.Store:Reserve("shelf", "Stock", 2, "cart1"):Wait()
	Shelf.Store:Edit("shelf", "Meddle"):Wait()
	local Now = Shelf:State("shelf")

	T:Accuses("it named itself for a mistake the reducer made", "your reducer wrote its own _Booked")
	T:Is("the forged booking", Now._Booked["forged"], nil)
	T:Is("the real one", Now._Booked["cart1"].Amount, 2)
	T:Is("stock left", Now.Stock, 8)
end)

Cases.Case("reserving from a field that is not there is refused", function(T: Case)
	local Shelf = T:Shelf()

	T:Throws("reserving from a field the Default never declared", function()
		Shelf.Store:Reserve("shelf", "Nonsense", 1, "cart1"):Wait()
	end)
	T:Throws("reserving a negative amount", function()
		Shelf.Store:Reserve("shelf", "Stock", -1, "cart2"):Wait()
	end)
	T:Is("stock, untouched", Shelf:Amount("shelf"), 10)
end)

Cases.Case("bookings and transfers do not disturb each other", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("bookA", { Gold = 100 })
	Bank:Seed("bookB", { Gold = 0 })

	Bank.Store:Reserve("bookA", "Gold", 30, "hold1"):Wait()
	local Moved = Bank.Store:Transfer("bookA", "bookB", 50, "send1"):Wait()
	local Sa = Bank:State("bookA")

	T:Is("the transfer alongside a booking", Moved, true)
	T:Is("gold on the sender", Sa.Gold, 20)
	T:Is("gold on the receiver", Bank:Amount("bookB"), 50)
	T:Is("the booking, untouched by the transfer", Sa._Booked["hold1"].Amount, 30)
	T:Is("nothing left in transfer escrow", Bank:Aside("bookA"), 0)
	T:Is("gold is conserved", Sa.Gold + Sa._Booked["hold1"].Amount + Bank:Amount("bookB"), 100)
end)

Cases.Case("a grant moves the units to the other key exactly once", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 3, "move1", { To = "cart" }):Wait()
	local Ok = Shelf.Store:Grant("shelf", "move1"):Wait()
	local Again = Shelf.Store:Grant("shelf", "move1"):Wait()

	T:Is("handing it over", Ok, true)
	T:Is("handing the same one over again", Again, false)
	T:Is("stock left with the sender", Shelf:Amount("shelf"), 7)
	T:Is("stock the receiver got", Shelf:Amount("cart"), 13)
	T:Is("anything still set aside", Shelf:Booked("shelf"), 0)
	T:Is("stock is conserved", Shelf:Amount("shelf") + Shelf:Amount("cart"), 20)
end)

Cases.Case("confirming a booking that was handed over is refused", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 3, "move1", { To = "cart" }):Wait()
	local Gave = Shelf.Store:Grant("shelf", "move1"):Wait()
	local Took, Why = Shelf.Store:Confirm("shelf", "move1"):Wait()

	T:Is("handing it over", Gave, true)
	T:Is("confirming units that went to another key", Took, false)
	T:Is("the reason, since the sender never spent them itself", Why, "Refused")
	T:Is("stock left with the sender", Shelf:Amount("shelf"), 7)
	T:Is("stock the receiver got", Shelf:Amount("cart"), 13)
	T:Is("stock is conserved", Shelf:Amount("shelf") + Shelf:Amount("cart"), 20)
end)

Cases.Case("a booking spent before the hand over marks it hands nothing over", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 3, "move1", { To = "cart" }):Wait()
	local Held = assert(Booking.Entry(Shelf:Stored("shelf")._Booked, "move1"), "the reservation was not set aside")

	Shelf.Store:Confirm("shelf", "move1"):Wait()
	local Gave = Shelf.Store:Handed("shelf", "move1", Held)

	T:Is("handing over a booking that was confirmed first", Gave, false)
	T:Is("stock the receiver never got", Shelf:Amount("cart"), 10)
	T:Is("stock left with the sender, which the confirm spent", Shelf:Amount("shelf"), 7)
	T:Is("anything still set aside", Shelf:Booked("shelf"), 0)
end)

Cases.Case("a booking given back before the hand over marks it hands nothing over", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 3, "move1", { To = "cart" }):Wait()
	local Held = assert(Booking.Entry(Shelf:Stored("shelf")._Booked, "move1"), "the reservation was not set aside")

	Shelf.Store:Release("shelf", "move1"):Wait()
	local Gave = Shelf.Store:Handed("shelf", "move1", Held)

	T:Is("handing over a booking that was released first", Gave, false)
	T:Is("stock the receiver never got", Shelf:Amount("cart"), 10)
	T:Is("stock given back to the sender", Shelf:Amount("shelf"), 10)
	T:Is("stock is conserved", Shelf:Amount("shelf") + Shelf:Amount("cart"), 20)
end)

Cases.Case("a grant racing a confirm leaves the units in exactly one place", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("shelf", "Stock", 3, "move1", { To = "cart" }):Wait()

	local Gave, Took = false, false
	T:Race({
		function()
			Gave = (Shelf.Store:Grant("shelf", "move1"):Wait())
		end,
		function()
			Took = (Shelf.Store:Confirm("shelf", "move1"):Wait())
		end,
	})

	local Delivered = Booking.Delivered(Shelf:Stored("cart"), "move1")
	local Places = (if Shelf:Amount("shelf") == 10 then 1 else 0) + (if Delivered then 1 else 0) + (if Took then 1 else 0)

	T:Is("how many places the units ended up in", Places, 1)
	T:Is("how many callers were told they got them", (if Gave then 1 else 0) + (if Took then 1 else 0), 1)
	T:Is("the receiver holds them only if the grant said so", Delivered, Gave)
	T:Is("anything still set aside", Shelf:Booked("shelf"), 0)
end)

Cases.Case("a grant that dies after delivering is finished not given back", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 4, "half1", { To = "cart" }):Wait()

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
	T:Is("anything still set aside", Shelf:Booked("shelf"), 0)
	T:Is("stock is conserved", Shelf:Amount("shelf") + Shelf:Amount("cart"), 20)
end)

Cases.Case("a grant that never delivered is given back", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 4, "never1", { To = "cart" }):Wait()
	T:Is("stock while it is held", Shelf:Amount("shelf"), 6)

	T:Advance(STALE)
	Shelf.Store:Peek("shelf"):Wait()
	T:Sweep()

	T:Is("stock given back to the sender", Shelf:Amount("shelf"), 10)
	T:Is("stock the receiver never got", Shelf:Amount("cart"), 10)
	T:Is("anything still set aside", Shelf:Booked("shelf"), 0)
end)

Cases.Case("a grant into an erased key keeps the units with the sender", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Edit("cart", "Sell"):Wait()
	Shelf.Store:Erase("cart"):Wait()

	Shelf.Store:Reserve("shelf", "Stock", 5, "tomb1", { To = "cart" }):Wait()
	local Ok, Why = Shelf.Store:Grant("shelf", "tomb1"):Wait()

	T:Is("handing it into an erased key", Ok, false)
	T:Is("the reason, since the units left the sender", Why, "Held")
	T:Is("the units, still set aside", Shelf:Booked("shelf"), 1)
	T:Is("stock the receiver did not get", Shelf:Amount("cart"), 10)
end)

Cases.Case("a grant the receiver would not take keeps the units", function(T: Case)
	local Shelf = T:Store({ Default = { Stock = 10 }, Reducer = Spoiling, Field = "Stock" })

	Shelf.Store:Edit("cart", "Spoil"):Wait()
	Shelf.Store:Reserve("shelf", "Stock", 4, "bad1", { To = "cart" }):Wait()

	local Ok, Why = Shelf.Store:Grant("shelf", "bad1"):Wait()

	T:Is("handing units to a key that will not take them", Ok, false)
	T:Is("the reason, since the units left the sender", Why, "Held")
	T:Is("stock the sender still has", Shelf:Amount("shelf"), 6)
	T:Is("the units, still set aside rather than gone", Shelf:Booked("shelf"), 1)
	T:Is("ops left on the receiver", #Shelf:Record("cart").Ops, 1)

	local Gave, Refused = Shelf.Store:Release("shelf", "bad1"):Wait()
	T:Is("giving them back by hand", Gave, false)
	T:Is("the reason", Refused, "Held")
	T:Warns("it said recovery owns it", "is being handed to another key")

	T:Advance(STALE)
	T:Sweep()
	T:Is("stock once recovery has given them back", Shelf:Amount("shelf"), 10)
	T:Is("anything still set aside", Shelf:Booked("shelf"), 0)
end)

Cases.Case("a reservation with no destination cannot be granted", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 2, "plain1"):Wait()
	local Ok = Shelf.Store:Grant("shelf", "plain1"):Wait()

	T:Is("handing over a reservation that names nowhere", Ok, false)
	T:Is("the units, still set aside", Shelf:Booked("shelf"), 1)
	T:Is("confirming it instead", Shelf.Store:Confirm("shelf", "plain1"):Wait(), true)
end)

Cases.Case("a reservation can be held for longer than the default", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 4, "slow", { Hold = Windows.BOOK * 4 }):Wait()
	T:Advance(STALE)

	Shelf.Store:Reserve("shelf", "Stock", 1, "quick"):Wait()
	local Now = Shelf:State("shelf")

	T:Is("a longer hold outliving the usual window", Now._Booked["slow"].Amount, 4)
	T:Is("stock, with both still held", Now.Stock, 5)
	T:Is("confirming the longer one", Shelf.Store:Confirm("shelf", "slow"):Wait(), true)
end)

Cases.Case("the sweep gives back a reservation on a key nobody touches", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 6, "walkedaway"):Wait()
	Shelf.Store:Peek("shelf"):Wait()
	local Stranded = Shelf:Amount("shelf")

	T:Advance(STALE)
	T:Sweep()

	T:Is("stock while the reservation is held", Stranded, 4)
	T:Is("stock once the sweep gives it back", Shelf:Amount("shelf"), 10)
	T:Is("reservations left", Shelf:Booked("shelf"), 0)
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

	T:Is("a bump that names no Default, read on its own", Alone, 10)
	T:Is("the tally once another bump lands on it", Moved, 15)
	T:Is("a third bump landing after those two", Shelf.Store:Total("pot", "Gold"):Wait(), 22)
end)

Cases.Case("a reset says which reservations it destroyed", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()
	local Before = Shelf:Booked("shelf")
	local Reset = Shelf.Store:Reset("shelf"):Wait()

	T:Is("the reservation before the reset", Before, 1)
	T:Is("the reset, which a plain reservation does not stand in the way of", Reset, true)
	T:Is("what is set aside afterwards", Shelf:Booked("shelf"), 0)
	T:Is("releasing the id the caller is still holding", (Shelf.Store:Release("shelf", "cart1"):Wait()), false)
	T:Warns("it said the reservations went with it", "Confirm and Release on those ids are refused", 1)
end)

Cases.Case("a reset is refused while units are set aside for another key", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 3, "cart1", { To = "buyer" }):Wait()
	local Ok, Why = Shelf.Store:Reset("shelf"):Wait()

	T:Is("the reset", Ok, false)
	T:Is("the reason", Why, "Busy")
	T:Is("the booking it would have dropped", Shelf:Booked("shelf"), 1)
end)

Cases.Case("a reset cannot leave granted units on both keys", function(T: Case)
	local Shelf = T:Shelf()

	local Before = Shelf:Amount("shelf") + Shelf:Amount("buyer")
	Shelf.Store:Reserve("shelf", "Stock", 3, "cart1", { To = "buyer" }):Wait()

	local Held = assert(Booking.Entry(Shelf:Stored("shelf")._Booked, "cart1"), "the reservation was not set aside")
	Shelf:Append("buyer", { Booking.Give("cart1", Held.Field, Held.Amount, Booking.Terms("shelf", "cart1", Held)) })

	local Reset = Shelf.Store:Reset("shelf"):Wait()
	Shelf:Append("shelf", { Booking.Take("cart1") })

	T:Is("a reset in the middle of a hand over", Reset, false)
	T:Is("stock across both keys", Shelf:Amount("shelf") + Shelf:Amount("buyer"), Before)
end)

local function Stranded(T: Case, Count: number, To: string?, Handing: boolean?): any
	local Shelf = T:Shelf()
	local Booked: { [string]: any } = {}
	for Index = 1, Count do
		Booked[`old{Index}`] = { Field = "Stock", Amount = 1, At = T:Now(), To = To, Handing = Handing }
	end
	Shelf:Write("shelf", { Snapshot = { Stock = 10, Sold = 0, Gold = 0, _Booked = Booked }, Ops = {}, Seen = {} })
	return Shelf
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
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("shelf", "Stock", 3, "cart1", { To = "buyer" }):Wait()

	local Held = assert(Booking.Entry(Shelf:Stored("shelf")._Booked, "cart1"), "the reservation was not set aside")
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
	Shelf.Store:Reserve("shelf", "Stock", 3, "cart1", { To = "buyer" }):Wait()

	local Ok, Why = Shelf.Store:Grant("shelf", "cart1"):Wait()

	T:Accuses("it noticed the units had been given back", "had already given the same units back")
	T:Is("the hand over", Ok, false)
	T:Is("the reason", Why, "Unresolved")
end)

Cases.Case("a key stops taking reservations at the cap", function(T: Case)
	local Shelf = T:Shelf()
	Sizes.Set({ Booked = 2 })

	T:Is("the first", (Shelf.Store:Reserve("shelf", "Stock", 1, "b1"):Wait()), true)
	T:Is("the second", (Shelf.Store:Reserve("shelf", "Stock", 1, "b2"):Wait()), true)

	local Ok, Why = Shelf.Store:Reserve("shelf", "Stock", 1, "b3"):Wait()
	T:Is("the one past the cap", Ok, false)
	T:Is("the reason", Why, Reasons.Refused)
	T:Is("what the key holds", Shelf:Booked("shelf"), 2)
	T:Is("the units it did not take", Shelf:Amount("shelf"), 8)
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

Cases.Case("a hold too long to be given back is refused", function(T: Case)
	local Shelf = T:Shelf()
	Shelf:Seed("capA", { Stock = 10, Sold = 0, Gold = 0 })
	Shelf:Seed("capB", { Stock = 0, Sold = 0, Gold = 0 })

	T:Holds("a hold right on the cap", function()
		Shelf.Store:Reserve("capA", "Stock", 1, "capfits", { Hold = Windows.HOLD_CAP, To = "capB" }):Wait()
	end)

	local Says = T:Throws("a hold past the cap", function()
		Shelf.Store:Reserve("capA", "Stock", 1, "caplong", { Hold = Windows.HOLD_CAP + 1, To = "capB" })
	end)

	T:Holds("a long hold with nowhere to hand it to", function()
		Shelf.Store:Reserve("capA", "Stock", 1, "capfree", { Hold = Windows.HOLD_CAP * 2 }):Wait()
	end)

	T:Ok("it said what a longer hold does", string.find(tostring(Says), "written off instead of given back", 1, true) ~= nil)
	T:Is("units set aside by the two that went through", Shelf:Booked("capA"), 2)
end)

Cases.Case("an erase hands over the units it owes another key", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("shelf", "Stock", 3, "move1", { To = "cart" }):Wait()

	T:Is("stock left on the shelf once it is set aside", Shelf:Amount("shelf"), 7)
	T:Is("stock the receiver holds before the erase", Shelf:Amount("cart"), 10)

	T:Is("erasing the key the units are owed by", Shelf.Store:Erase("shelf"):Wait(), true)

	T:Is("stock the receiver got", Shelf:Amount("cart"), 13)
	T:Is("anything still set aside", Shelf:Booked("shelf"), 0)
	T:Silent("nothing was destroyed on the way out", "destroyed 1 reservation")
end)

Cases.Case("an erase cannot hand over units the receiver will not take", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("shelf", "Stock", 3, "move1", { To = "cart" }):Wait()
	Shelf.Store:Erase("cart"):Wait()

	T:Is("erasing the key the units are owed by", Shelf.Store:Erase("shelf"):Wait(), true)

	T:Is("stock the erased receiver got", Shelf:Amount("cart"), 10)
	T:Warns("it named the booking it could not hand over", "could not hand booking 'move1'")
	T:Warns("it named what went with the key", "destroyed 1 reservation(s) holding 3 Stock")
end)

Cases.Case("an erase leaves a booking that is owed to nobody alone", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("shelf", "Stock", 3, "keep1"):Wait()

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

Cases.Case("two servers granting one booking hand the units over once", function(T: Case)
	local One, Two = T:Shelf("nodeA"), T:Shelf("nodeB")
	One:Seed("twinshelf", { Stock = 10, Sold = 0, Gold = 0 })
	One:Seed("twincart", { Stock = 0, Sold = 0, Gold = 0 })
	One.Store:Reserve("twinshelf", "Stock", 3, "twin1", { To = "twincart" }):Wait()

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

Cases.Case("a booking past its hold is still spent by a confirm that gets there first", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("holdA", "Stock", 3, "holdA1"):Wait()

	T:Advance(STALE)

	T:Is("confirming it once its hold has run out", (Shelf.Store:Confirm("holdA", "holdA1"):Wait()), true)
	T:Is("the stock it spent, which was already set aside", Shelf:Amount("holdA"), 7)
	T:Is("nothing is left set aside", Shelf:Booked("holdA"), 0)
end)

Cases.Case("a booking the next reservation gave back cannot be confirmed", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("holdB", "Stock", 3, "holdB1"):Wait()

	T:Advance(STALE)
	Shelf.Store:Reserve("holdB", "Stock", 1, "holdB2"):Wait()

	T:Is("the stale booking went back before the new one took its units", Shelf:Amount("holdB"), 9)
	T:Is("confirming the one that was given back", (Shelf.Store:Confirm("holdB", "holdB1"):Wait()), false)
	T:Is("the stock is left where it went", Shelf:Amount("holdB"), 9)
	T:Is("only the newer booking is set aside", Shelf:Booked("holdB"), 1)
end)

Cases.Case("a hand over past its hold is refused where a confirm would not be", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("holdC", "Stock", 3, "holdC1", { To = "holdCart" }):Wait()

	T:Advance(STALE)
	local Ok, Why = Shelf.Store:Grant("holdC", "holdC1"):Wait()

	T:Is("handing it over once its hold has run out", Ok, false)
	T:Is("the reason", Why, "Spent")
	T:Is("the units are left set aside for recovery", Shelf:Booked("holdC"), 1)
	T:Is("and the receiver was given nothing", Shelf:Amount("holdCart"), 10)
end)

Cases.Case("a booking replayed after its op was compacted away cannot be answered", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("faded", "Stock", 2, "faded1"):Wait()

	T:Is("confirming it", (Shelf.Store:Confirm("faded", "faded1"):Wait()), true)
	T:Is("confirming again while the op is still in the log", (Shelf.Store:Confirm("faded", "faded1"):Wait()), true)

	Shelf:Log():Compact("faded", Shelf:Format())
	local Late, Why = Shelf.Store:Confirm("faded", "faded1"):Wait()

	T:Is("confirming again once the op has been folded into the snapshot", Late, false)
	T:Is("the reason, since the record can no longer say whether it took or was turned away", Why, "Unresolved")
	T:Is("the units were still spent exactly once", Shelf:Amount("faded"), 8)
	T:Is("and nothing is left set aside", Shelf:Booked("faded"), 0)
end)

Cases.Case("units are protected by the booking being gone, not by remembering the op", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("proof", "Stock", 2, "proof1"):Wait()
	Shelf.Store:Confirm("proof", "proof1"):Wait()
	Shelf:Forget("proof", { `{Kinds.TAKE_ID}:`, `{Kinds.BOOK_ID}:` })

	T:Is("nothing is left of the confirm, in the log or in what was seen", #Shelf:Record("proof").Seen, 0)
	T:Is("confirming again with every trace of it gone", (Shelf.Store:Confirm("proof", "proof1"):Wait()), false)
	T:Is("the units are still spent exactly once", Shelf:Amount("proof"), 8)

	Shelf.Store:Reserve("kept", "Stock", 2, "kept1"):Wait()
	Shelf.Store:Release("kept", "kept1"):Wait()
	Shelf:Forget("kept", { `{Kinds.FREE_ID}:`, `{Kinds.BOOK_ID}:` })

	T:Is("releasing again with every trace of it gone", (Shelf.Store:Release("kept", "kept1"):Wait()), false)
	T:Is("the units are given back exactly once", Shelf:Amount("kept"), 10)
end)

Cases.Case("a booking name can be used again once its booking is gone", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("reuse", "Stock", 2, "reuse1"):Wait()
	Shelf.Store:Confirm("reuse", "reuse1"):Wait()
	Shelf:Forget("reuse", { `{Kinds.TAKE_ID}:`, `{Kinds.BOOK_ID}:` })

	T:Is("reserving under the same name again", (Shelf.Store:Reserve("reuse", "Stock", 2, "reuse1"):Wait()), true)
	T:Is("the units it set aside this time", Shelf:Booked("reuse"), 1)
	T:Is("the stock left after both", Shelf:Amount("reuse"), 6)
end)

Cases.Case("a booking can still be released after it has been compacted into the snapshot", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("packed", "Stock", 3, "packed1"):Wait()

	Shelf:Log():Compact("packed", Shelf:Format())

	T:Is("ops left after compaction", #Shelf:Record("packed").Ops, 0)
	T:Is("the booking, now living in the snapshot", Shelf:Booked("packed"), 1)
	T:Is("releasing it from there", (Shelf.Store:Release("packed", "packed1"):Wait()), true)
	T:Is("the units it gave back", Shelf:Amount("packed"), 10)
	T:Is("nothing is left set aside", Shelf:Booked("packed"), 0)
end)

Cases.Case("a booking compacted into the snapshot still runs out on its own", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("ticking", "Stock", 3, "ticking1"):Wait()

	Shelf:Log():Compact("ticking", Shelf:Format())
	T:Advance(STALE)
	Shelf.Store:Reserve("ticking", "Stock", 1, "ticking2"):Wait()

	T:Is("the stale booking went back before the new one took its units", Shelf:Amount("ticking"), 9)
	T:Is("only the newer booking is set aside", Shelf:Booked("ticking"), 1)
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

	Shelf:Fault(Fault.Reads():OnKey(Tally.Shard("part", 0)))
	Shelf:NoRetries()
	local Sum, Why = Shelf.Store:Total("part", "Gold"):Wait()

	T:Is("the total with one shard unreadable", Sum, nil)
	T:Is("the reason, since a number would be wrong rather than late", Why, "Unresolved")
end)

Cases.Case("a grant whose booking another server gave back hands nothing over", function(T: Case)
	local One, Two = T:Shelf("granta"), T:Shelf("grantb")
	One:Seed("gsrc", { Stock = 10, Sold = 0, Gold = 0 })
	One:Seed("gdst", { Stock = 0, Sold = 0, Gold = 0 })

	One.Store:Reserve("gsrc", "Stock", 3, "gswap1", { To = "gdst" }):Wait()
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

Cases.Case("reserving under a name whose units have gone says so rather than reporting success", function(T: Case)
	local Shelf = T:Shelf()
	Shelf:Seed("spent", { Stock = 10, Sold = 0, Gold = 0 })

	T:Is("the first reservation", (Shelf.Store:Reserve("spent", "Stock", 3, "spent1"):Wait()), true)
	T:Is("asking again while it is still held", (Shelf.Store:Reserve("spent", "Stock", 3, "spent1"):Wait()), true)
	T:Is("the units it set aside, which is one booking and not two", Shelf:Booked("spent"), 1)

	T:Is("giving it back", (Shelf.Store:Release("spent", "spent1"):Wait()), true)

	local Again, Why = Shelf.Store:Reserve("spent", "Stock", 5, "spent1"):Wait()

	T:Is("reserving under that name once its units have gone", Again, false)
	T:Is("the reason", Why, "Spent")
	T:Is("nothing was set aside", Shelf:Booked("spent"), 0)
	T:Is("and the stock is whole", Shelf:Amount("spent"), 10)
	T:Warns("it said the name cannot be used again", "was used before and its units have gone", 1)
end)

Cases.Case("resettling a key that is only holding a live booking says it is still busy", function(T: Case)
	local Shelf = T:Shelf()
	Shelf:Seed("resting", { Stock = 10, Sold = 0, Gold = 0 })

	T:Is("resettling it while nothing is on it", (Shelf.Store:Resettle("resting"):Wait()), true)

	Shelf.Store:Reserve("resting", "Stock", 3, "resting1"):Wait()
	local Ok, Why = Shelf.Store:Resettle("resting"):Wait()

	T:Is("resettling it while it holds a live booking", Ok, false)
	T:Is("the reason, since those units are still to be decided", Why, "Busy")
	T:Is("the booking is left exactly as it was", Shelf:Booked("resting"), 1)
	T:Is("and so is the stock it set aside", Shelf:Amount("resting"), 7)
end)

return Cases
