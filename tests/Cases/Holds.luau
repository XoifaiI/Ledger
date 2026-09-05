--!strict
--!optimize 2

--[=[

	Holds: One rule per case for units held on a single key in MemoryStore.

	A hold lives in MemoryStore and never in the fold. Reserving units, confirming them with the
	game's own op, and releasing them. Letting a hold run out, and what a hold costs. What the reducer
	refuses at checkout, however many are held. The field transfers and the tallies are in Booking,
	which runs whether or not there is a MemoryStore.
	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, then run zune run zune/Cases.luau holds
--]=]

local Suite = require("../Suite")

local Windows = require("../../src/Core/Constants/Windows")
local Sizes = require("../../src/Core/Constants/Sizes")
local Bookings = require("../../src/Core/Constants/Bookings")
local Mark = require("../../src/Encode/Mark")
local MemoryStore = require("../../src/Core/Constants/MemoryStore")

local Fault = Suite.Fault
local Reducers = Suite.Reducers
local Reasons = Suite.Reasons

type Case = Suite.Case
type Fixture = Suite.Fixture

local STALE = Windows.BOOK + Windows.BOOK_MARGIN + 60
local MAP = Bookings.MAP

local Cases = Suite.File("Holds", { "cache" })

local function Holds(Shelf: Fixture, Key: string, Field: string?): number?
	return (Shelf.Store:Holds(Key, Field or "Stock"):Wait())
end

local function Item(T: Case, Shelf: Fixture, Key: string): any
	return T.Service:GetHashMap(MAP):GetAsync(Mark.Cached({ Shelf.Data, Key }))
end

local function Sell(Shelf: Fixture, Key: string, Rid: string, Count: number): (boolean, any)
	return Shelf.Store:Confirm(Key, Rid, "Sell", { Count = Count }):Wait()
end

local function Reads(Shelf: Fixture, Body: () -> ()): number
	local Before = Shelf.Store.Wrapper.Spent
	Body()
	return Shelf.Store.Wrapper.Spent - Before
end

local function Units(T: Case, Body: () -> ()): number
	local Before = T.Service.Units
	Body()
	return T.Service.Units - Before
end

Cases.Case("a reservation holds units without spending them", function(T: Case)
	local Shelf = T:Shelf()

	local Ok, Why = Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()
	local Now = Shelf:State("shelf")

	T:Is("the reservation", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("stock the key reads, untouched by the hold", Now.Stock, 10)
	T:Is("anything the fold set aside", Now._Booked, nil)
	T:Is("units held on the key", Holds(Shelf, "shelf"), 3)
end)

Cases.Case("confirming a booking spends the units with the game's own op", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()
	local Ok, Why = Sell(Shelf, "shelf", "cart1", 3)
	local Now = Shelf:State("shelf")

	T:Is("confirming the booking", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("stock left once the op took it", Now.Stock, 7)
	T:Is("what the reducer counted", Now.Sold, 3)
	T:Is("units still held", Holds(Shelf, "shelf"), 0)
	T:Is("names the confirm left on the key, which would grow with every sale", next(Shelf:Names("shelf")), nil)
end)

Cases.Case("releasing a booking lets the units go", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 4, "cart1"):Wait()
	local Ok = Shelf.Store:Release("shelf", "cart1"):Wait()

	T:Is("releasing the booking", Ok, true)
	T:Is("stock, never touched", Shelf:Amount("shelf"), 10)
	T:Is("units still held", Holds(Shelf, "shelf"), 0)
end)

Cases.Case("more cannot be held than the field has", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 8, "cart1"):Wait()
	local Ok, Why = Shelf.Store:Reserve("shelf", "Stock", 5, "cart2"):Wait()

	T:Is("a reservation the shelf cannot cover", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("units held", Holds(Shelf, "shelf"), 8)
	T:Is("stock, which no hold touches", Shelf:Amount("shelf"), 10)
	T:Silent("it refused cleanly rather than tripping a guard", "a bug in Ledger")
end)

Cases.Case("ten buyers hold ten units and the eleventh is turned away", function(T: Case)
	local Shelf = T:Shelf()

	local Taken = 0
	for Index = 1, 11 do
		if Shelf.Store:Reserve("shelf", "Stock", 1, `buyer{Index}`):Wait() then
			Taken += 1
			T:Ok(`buyer {Index} checks out`, (Sell(Shelf, "shelf", `buyer{Index}`, 1)))
		end
	end

	T:Is("buyers who got one", Taken, 10)
	T:Is("stock left", Shelf:Amount("shelf"), 0)
	T:Is("units still held", Holds(Shelf, "shelf"), 0)
end)

Cases.Case("asking again under the same name holds nothing extra", function(T: Case)
	local Shelf = T:Shelf()

	local First = Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()
	local Again = Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()

	T:Is("the first reservation", First, true)
	T:Is("asking again under the same name", Again, true)
	T:Is("units held, once and not twice", Holds(Shelf, "shelf"), 3)
end)

Cases.Case("confirming twice spends once", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 2, "cart1"):Wait()
	local First = Sell(Shelf, "shelf", "cart1", 2)
	local Again = Sell(Shelf, "shelf", "cart1", 2)

	T:Is("confirming it", First, true)
	T:Is("confirming the same booking again", Again, true)
	T:Is("stock left", Shelf:Amount("shelf"), 8)
	T:Is("units still held", Holds(Shelf, "shelf"), 0)
end)

Cases.Case("the reducer is the gate at checkout, with a hold or without one", function(T: Case)
	local Shelf = T:Shelf()

	local Unheld = Sell(Shelf, "shelf", "walkin", 1)
	Shelf.Store:Reserve("shelf", "Stock", 6, "held"):Wait()
	T:Ok("an edit that takes held units anyway, since a hold is not in the fold", (Shelf.Store:Edit("shelf", "Sell", { Count = 8 }):Wait()))
	local Ok, Why = Sell(Shelf, "shelf", "held", 6)

	T:Is("a confirm with no hold behind it", Unheld, true)
	T:Is("a confirm whose units an edit took first", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("stock left", Shelf:Amount("shelf"), 1)
	T:Is("the hold, still there for its own time", Holds(Shelf, "shelf"), 6)
end)

Cases.Case("a hold runs out on its own and the next reservation can have the units", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 6, "abandoned"):Wait()
	local Blocked = Shelf.Store:Reserve("shelf", "Stock", 6, "early"):Wait()
	T:Advance(STALE)
	local Later = Shelf.Store:Reserve("shelf", "Stock", 6, "fresh"):Wait()

	T:Is("a second reservation while the first is held", Blocked, false)
	T:Is("the same reservation once the first ran out", Later, true)
	T:Is("units held, the fresh one only", Holds(Shelf, "shelf"), 6)
end)

Cases.Case("a shorter hold beside a longer one leaves the longer one alone", function(T: Case)
	local Shelf = T:Shelf()

	Shelf.Store:Reserve("shelf", "Stock", 4, "slow", { Hold = Windows.BOOK }):Wait()
	T:Advance(Windows.BOOK - 60)
	Shelf.Store:Reserve("shelf", "Stock", 1, "quick", { Hold = 30 }):Wait()

	T:Is("units held, the long one and the quick one", Holds(Shelf, "shelf"), 5)
	T:Is("confirming the long one", (Sell(Shelf, "shelf", "slow", 4)), true)
	T:Is("stock once it is spent", Shelf:Amount("shelf"), 6)
end)

Cases.Case("a reservation is one write, so nothing can be dropped between two of them", function(T: Case)
	local Shelf = T:Shelf()
	T:Ok("a first reservation that seeds the item", (Shelf.Store:Reserve("shelf", "Stock", 1, "seed"):Wait()))
	T:Ok("giving it back", (Shelf.Store:Release("shelf", "seed"):Wait()))
	local Lost = Shelf.Hook.Fail(Fault.Updates():OnStore(MAP):After(1))

	local Spent = Units(T, function()
		T:Ok("a reservation for the longest hold there is", (Shelf.Store:Reserve("shelf", "Stock", 4, "slow", { Hold = Windows.BOOK }):Wait()))
	end)
	T:Advance(Windows.BOOK - 60)
	local Nearly = Holds(Shelf, "shelf")
	T:Advance(120)

	T:Is("units on a reservation for the longest hold", Spent, MemoryStore.UPDATE_UNITS)
	T:Is("writes the fault had left to drop, since the reservation made one", Lost.Fired, 0)
	T:Is("units held just before the hold runs out", Nearly, 4)
	T:Is("units held once it has", Holds(Shelf, "shelf"), 0)
end)

Cases.Case("a hold is kept alive by reserving again under the same name", function(T: Case)
	local Shelf = T:Shelf()
	T:Ok("the reservation", (Shelf.Store:Reserve("shelf", "Stock", 4, "cart1"):Wait()))
	T:Advance(Windows.BOOK - 60)
	T:Ok("asking again before it runs out", (Shelf.Store:Reserve("shelf", "Stock", 4, "cart1"):Wait()))
	T:Advance(120)
	local Kept = Holds(Shelf, "shelf")
	T:Advance(Windows.BOOK)

	T:Is("units held past where the first hold would have ended, the one hold and not two", Kept, 4)
	T:Is("units held once the second hold runs out", Holds(Shelf, "shelf"), 0)
end)

Cases.Case("a hold past the cap is refused where the call was written", function(T: Case)
	local Shelf = T:Shelf()

	T:Holds("a hold right on the cap", function()
		Shelf.Store:Reserve("shelf", "Stock", 1, "capfits", { Hold = Windows.BOOK }):Wait()
	end)
	T:Throws("a hold past the cap, which is the window the item lives for", function()
		Shelf.Store:Reserve("shelf", "Stock", 1, "caplong", { Hold = Windows.BOOK + 1 })
	end)
	T:Throws("a destination, which a hold no longer takes", function()
		Shelf.Store:Reserve("shelf", "Stock", 1, "capto", { To = "cart" } :: any)
	end)
	T:Throws("reserving from a field the Default never declared", function()
		Shelf.Store:Reserve("shelf", "Nonsense", 1, "cart1"):Wait()
	end)
	T:Throws("reserving a negative amount", function()
		Shelf.Store:Reserve("shelf", "Stock", -1, "cart2"):Wait()
	end)
	T:Is("units held by the one that went through", Holds(Shelf, "shelf"), 1)
end)

Cases.Case("a hold is invisible to a plain read and counted by Holds", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()

	T:Is("stock a read shows", (Shelf.Store:Peek("shelf"):Wait() :: any).Stock, 10)
	T:Is("units Holds shows", Holds(Shelf, "shelf"), 3)
	T:Is("units held on a field nothing holds", Holds(Shelf, "shelf", "Gold"), 0)
	T:Is("units held on a key nothing touched", Holds(Shelf, "empty"), 0)
end)

Cases.Case("a key stops taking holds at the cap", function(T: Case)
	local Shelf = T:Shelf()
	Sizes.Set({ Booked = 2 })

	T:Is("the first", (Shelf.Store:Reserve("shelf", "Stock", 1, "b1"):Wait()), true)
	T:Is("the second", (Shelf.Store:Reserve("shelf", "Stock", 1, "b2"):Wait()), true)

	local Ok, Why = Shelf.Store:Reserve("shelf", "Stock", 1, "b3"):Wait()
	T:Is("the one past the cap", Ok, false)
	T:Is("the reason", Why, Reasons.Refused)
	T:Is("units held", Holds(Shelf, "shelf"), 2)
	T:Warns("it said the key is at the cap", "already holds 2 reservations")
end)

Cases.Case("a cold reservation reads the key once and a warm one reads nothing", function(T: Case)
	local Shelf = T:Shelf()

	local ColdUnits = 0
	local Cold = Reads(Shelf, function()
		ColdUnits = Units(T, function()
			T:Ok("the cold reservation", (Shelf.Store:Reserve("shelf", "Stock", 1, "cold"):Wait()))
		end)
	end)
	local WarmUnits = 0
	local Warm = Reads(Shelf, function()
		WarmUnits = Units(T, function()
			T:Ok("the warm reservation", (Shelf.Store:Reserve("shelf", "Stock", 1, "warm"):Wait()))
		end)
	end)
	local ReleaseUnits = Units(T, function()
		T:Ok("the release", (Shelf.Store:Release("shelf", "warm"):Wait()))
	end)
	local HoldsUnits = Units(T, function()
		Holds(Shelf, "shelf")
	end)

	T:Is("datastore reads on the cold reservation", Cold, 1)
	T:Is("units on the cold reservation, an update that found nothing and one that seeded", ColdUnits, MemoryStore.UPDATE_UNITS * 2)
	T:Is("datastore reads on the warm reservation", Warm, 0)
	T:Is("units on the warm reservation", WarmUnits, MemoryStore.UPDATE_UNITS)
	T:Is("units on the release", ReleaseUnits, MemoryStore.UPDATE_UNITS)
	T:Is("units on a Holds", HoldsUnits, MemoryStore.UNIT)
end)

Cases.Case("a reservation the stock refuses reads the key again, so a restock is seen", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("shelf", "Stock", 10, "all"):Wait()
	T:Ok("the restock", (Shelf.Store:Edit("shelf", "Restock", { Count = 5 }):Wait()))

	local Ok
	local Read = Reads(Shelf, function()
		Ok = Shelf.Store:Reserve("shelf", "Stock", 3, "more"):Wait()
	end)
	local Again
	local Stale = Reads(Shelf, function()
		Again = Shelf.Store:Reserve("shelf", "Stock", 3, "toomany"):Wait()
	end)

	T:Is("a reservation the item's stale stock refused and the key allowed", Ok, true)
	T:Is("datastore reads to learn the restock", Read, 1)
	T:Is("a reservation the key refuses as well", Again, false)
	T:Is("datastore reads to be sure of that", Stale, 1)
	T:Is("units held", Holds(Shelf, "shelf"), 13)
end)

Cases.Case("a reservation whose MemoryStore is down answers Unresolved, and the reducer still refuses at checkout", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Hook.Fail(Fault.Updates():OnStore(MAP))

	local Ok, Why = Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()
	local Sold = Sell(Shelf, "shelf", "cart1", 3)
	local Refused, RefusedWhy = Sell(Shelf, "shelf", "cart2", 8)

	T:Is("the reservation", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("a checkout with no hold behind it", Sold, true)
	T:Is("a checkout the stock cannot cover", Refused, false)
	T:Is("its reason", RefusedWhy, "Refused")
	T:Is("stock left", Shelf:Amount("shelf"), 7)
	T:Warns("it said the map did not answer", "did not answer")
end)

Cases.Case("a confirm whose hold could not be let go still answers yes, and the hold runs out on its own", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("shelf", "Stock", 2, "cart1"):Wait()
	local Lost = Shelf.Hook.Fail(Fault.Updates():OnStore(MAP))

	local Ok = Sell(Shelf, "shelf", "cart1", 2)
	Shelf:Healed()
	local Lingering = Holds(Shelf, "shelf")
	T:Advance(STALE)

	T:Is("the confirm", Ok, true)
	T:Is("the drop that was lost", Lost.Fired, 1)
	T:Is("stock, spent", Shelf:Amount("shelf"), 8)
	T:Is("units still held until the hold runs out", Lingering, 2)
	T:Is("units held once it has", Holds(Shelf, "shelf"), 0)
end)

Cases.Case("a release that finds no hold and no old booking says so, and one that cannot look does not guess", function(T: Case)
	local Shelf = T:Shelf()

	local Ok, Why = Shelf.Store:Release("shelf", "never"):Wait()
	Shelf.Hook.Fail(Fault.Updates():OnStore(MAP))
	local Blind, BlindWhy = Shelf.Store:Release("shelf", "never"):Wait()

	T:Is("the release", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("the release with the map down", Blind, false)
	T:Is("its reason, since the hold could not be looked at", BlindWhy, "Unresolved")
end)

Cases.Case("a booking name can be reserved again once its hold has gone", function(T: Case)
	local Shelf = T:Shelf()

	T:Is("the first reservation", (Shelf.Store:Reserve("reuse", "Stock", 2, "reuse1"):Wait()), true)
	T:Is("giving it back", (Shelf.Store:Release("reuse", "reuse1"):Wait()), true)
	T:Is("reserving under the same name again", (Shelf.Store:Reserve("reuse", "Stock", 5, "reuse1"):Wait()), true)
	T:Is("units held this time", Holds(Shelf, "reuse"), 5)
	T:Is("stock, untouched throughout", Shelf:Amount("reuse"), 10)
end)

Cases.Case("a hold does not make a key busy for Resettle, and a reset leaves it where it is", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("resting", "Stock", 3, "resting1"):Wait()

	T:Is("resettling a key that holds units", (Shelf.Store:Resettle("resting"):Wait()), true)
	T:Is("resetting it", (Shelf.Store:Reset("resting"):Wait()), true)
	T:Is("units still held after the reset", Holds(Shelf, "resting"), 3)
	T:Is("confirming after the reset, against the default stock", (Sell(Shelf, "resting", "resting1", 3)), true)
	T:Is("stock left", Shelf:Amount("resting"), 7)
end)

Cases.Case("an erase takes the key's holds with it", function(T: Case)
	local Shelf = T:Shelf()
	Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()

	T:Is("erasing the key", (Shelf.Store:Erase("shelf"):Wait()), true)
	T:Is("the item the holds lived in", Item(T, Shelf, "shelf"), nil)
	T:Is("units held", Holds(Shelf, "shelf"), 0)
end)

Cases.Case("two servers reserving the last unit hold it once", function(T: Case)
	local One, Two = T:Shelf("nodeA"), T:Shelf("nodeB")
	One:Seed("last", { Stock = 1, Sold = 0, Gold = 0 })

	local First, Second: any = nil, nil
	T:Race({
		function()
			First = One.Store:Reserve("last", "Stock", 1, "buyerA"):Wait()
		end,
		function()
			Second = Two.Store:Reserve("last", "Stock", 1, "buyerB"):Wait()
		end,
	})

	T:Is("how many of the two got it", (if First then 1 else 0) + (if Second then 1 else 0), 1)
	T:Is("units held", Holds(One, "last"), 1)
end)

Cases.Case("a hold on one field leaves another field's stock alone", function(T: Case)
	local Shelf = T:Store({ Default = { Stock = 10, Other = 5 }, Reducer = Reducers.Keep, Field = "Stock" })

	T:Is("a hold on the first field", (Shelf.Store:Reserve("shelf", "Stock", 8, "a"):Wait()), true)
	T:Is("a hold on the other, up to what it has", (Shelf.Store:Reserve("shelf", "Other", 5, "b"):Wait()), true)
	T:Is("one more on the other", (Shelf.Store:Reserve("shelf", "Other", 1, "c"):Wait()), false)
	T:Is("units held on the first", Holds(Shelf, "shelf", "Stock"), 8)
	T:Is("units held on the other", Holds(Shelf, "shelf", "Other"), 5)
end)

Cases.Case("a release that never reached a map says so rather than refusing", function(T: Case)
	local Shelf = T:Shelf()
	Shelf:Seed("rack", { Stock = 10, Sold = 0, Gold = 0 })
	Shelf.Store.Bookings = nil

	local _, ReserveWhy = Shelf.Store:Reserve("rack", "Stock", 1, "cart"):Wait()
	local _, HoldsWhy = Shelf.Store:Holds("rack", "Stock"):Wait()
	local Let, ReleaseWhy = Shelf.Store:Release("rack", "cart"):Wait()

	T:Is("reserve says it could not be resolved", ReserveWhy, Reasons.Unresolved)
	T:Is("holds says the same", HoldsWhy, Reasons.Unresolved)
	T:No("release let nothing go", Let)
	T:Is("and release says the same", ReleaseWhy, Reasons.Unresolved)
	T:Warns("it says the store has no memorystore", "needs a MemoryStore and this store has none")
end)

Cases.Case("a release the map answered for finds nothing and refuses", function(T: Case)
	local Shelf = T:Shelf()
	Shelf:Seed("rack", { Stock = 10, Sold = 0, Gold = 0 })

	local Let, Why = Shelf.Store:Release("rack", "cart"):Wait()

	T:No("release let nothing go", Let)
	T:Is("it says refused, since the map answered", Why, Reasons.Refused)
	T:Silent("and it does not blame the store for having no map", "needs a MemoryStore and this store has none")
end)

Cases.Case("a booking name reused after a confirm is spent, not sold again for nothing", function(T: Case)
	local Shelf = T:Shelf()
	T:Ok("the first reservation", (Shelf.Store:Reserve("shelf", "Stock", 3, "cart1"):Wait()))
	T:Ok("the first confirm", (Sell(Shelf, "shelf", "cart1", 3)))
	T:Ok("reserving again under the same name, which is free again", (Shelf.Store:Reserve("shelf", "Stock", 2, "cart1"):Wait()))

	local Ok, Why = Sell(Shelf, "shelf", "cart1", 2)
	local Now = Shelf:State("shelf")

	T:Is("the second confirm", Ok, false)
	T:Is("the reason", Why, Reasons.Spent)
	T:Is("stock, spent by the first confirm only", Now.Stock, 7)
	T:Is("what the reducer counted", Now.Sold, 3)
	T:Is("units the second booking still holds", Holds(Shelf, "shelf"), 2)
	T:Warns("it said the name was spent by an earlier confirm", "already spent by an earlier confirm")
end)

Cases.Case("a key with long names stops taking holds before its item is too big for the map", function(T: Case)
	local Field = "LimitedEditionStock"
	local Shelf = T:Store({ Default = { [Field] = 100000000 }, Reducer = Reducers.Keep, Field = Field })

	local Taken, Refused, Unresolved = 0, 0, 0
	for Index = 1, Sizes.Booked do
		local Ok, Why = Shelf.Store:Reserve("shelf", Field, 100000, string.format("%064d", Index)):Wait()
		if Ok then
			Taken += 1
		elseif Why == Reasons.Refused then
			Refused += 1
		else
			Unresolved += 1
		end
	end
	local Held = Item(T, Shelf, "shelf")
	local Bytes = #game:GetService("HttpService"):JSONEncode(Held)

	T:Ok("holds it took", Taken > 0)
	T:Ok("holds it turned away once the item was full", Refused > 0)
	T:Is("holds it could not answer", Unresolved, 0)
	T:Is("misses the map counted", Shelf.Store.Bookings.Missed, 0)
	T:Ok(`the item, {Bytes} bytes, inside the cap`, Bytes <= MemoryStore.MAX_ITEM)
	T:Ok("a small reserve on another key still answers", (Shelf.Store:Reserve("other", Field, 1, "small"):Wait()))
	T:AtMost("it said the key was full, once a window", "already holds", 1)
end)

Cases.Case("reserving again under a held name for other terms is spent and holds what it held", function(T: Case)
	local Shelf = T:Store({ Default = { Stock = 10, Other = 5 }, Reducer = Reducers.Keep, Field = "Stock" })
	T:Ok("two held", (Shelf.Store:Reserve("shelf", "Stock", 2, "cart1"):Wait()))

	local More, MoreWhy = Shelf.Store:Reserve("shelf", "Stock", 5, "cart1"):Wait()
	local Elsewhere, ElsewhereWhy = Shelf.Store:Reserve("shelf", "Other", 1, "cart1"):Wait()

	T:Is("asking for five under the name that holds two", More, false)
	T:Is("the reason", MoreWhy, Reasons.Spent)
	T:Is("asking for another field under it", Elsewhere, false)
	T:Is("the reason for the other field", ElsewhereWhy, Reasons.Spent)
	T:Is("units held on Stock, the two", Holds(Shelf, "shelf", "Stock"), 2)
	T:Is("units held on Other, none", Holds(Shelf, "shelf", "Other"), 0)
	T:Warns("it said what the name holds", "already holds 2 Stock")
	T:Is("asking for the two again, which keeps the hold alive", (Shelf.Store:Reserve("shelf", "Stock", 2, "cart1"):Wait()), true)
end)

Cases.Case("a key at its cap says so once a window, not once a refusal", function(T: Case)
	local Shelf = T:Shelf()
	Sizes.Set({ Booked = 2 })
	Shelf.Store:Reserve("shelf", "Stock", 1, "b1"):Wait()
	Shelf.Store:Reserve("shelf", "Stock", 1, "b2"):Wait()
	for Index = 3, 22 do
		T:No(`buyer {Index}`, (Shelf.Store:Reserve("shelf", "Stock", 1, `b{Index}`):Wait()))
	end
	T:Advance(Windows.AUTOSAVE + 1)
	T:No("a buyer a window later", (Shelf.Store:Reserve("shelf", "Stock", 1, "later"):Wait()))

	T:Warns("it said the key was full, once for the burst and once a window later", "already holds 2 reservations", 2)
end)

return Cases
