--!strict
--!optimize 2

--[=[
	Booking: One rule per case for units set aside on a single key.

	A booking holds units of a number field under a name, so limited stock can sit on one key. It
	promises the units are neither spendable nor lost while held, and that they come back if nobody
	takes them. Handing one to another key is two writes, so a server that stops between them leaves
	the units on both, and only recovery may decide which way it went.
	The tally cases are the other half: spread over its own keys, and only ever added to.

	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, and it runs the next time you press play.
--]=]

local Suite = require("../Suite")

local Fault = Suite.Fault
local Insides = Suite.Insides
local Reducers = Suite.Reducers

local Booking = Insides.Booking

type Case = Suite.Case

local STALE = Booking.BOOK_HORIZON + Booking.BOOK_MARGIN + 60

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
	T:Is("bookings held, the stale one having gone", Booking.Counted(Now._Booked), 1)
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
	T:Is("bookings held", Booking.Counted(Now._Booked), 2)
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

	Shelf.Store:Reserve("shelf", "Stock", 4, "slow", { Hold = Booking.BOOK_HORIZON * 4 }):Wait()
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

	local Before = T:Conflicts()
	for _, Shelf in Fleet do
		Shelf.Store:Bump("pot", "Gold", 1):Wait()
	end
	local Spread = T:Conflicts() - Before

	T:Is("the tally after every server added one", Fleet[1].Store:Total("pot", "Gold"):Wait(), 12)
	T:Is("servers made to retry against each other", Spread, 0)
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

return Cases
