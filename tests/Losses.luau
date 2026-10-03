--!strict

--[=[

	Losses: The cases for Record/Losses, one per rule of cuts 5.

	Each case builds a book's loss room by hand and names one more event on it. Room gives a build
	whose loss room is one byte short of the events given, so the next event must make the fold run.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Alphabet = require("../src/Encode/Alphabet")
local Book = require("../src/Record/Book")
local Game = require("./Gold")
local Losses = require("../src/Record/Losses")
local Types = require("../src/Record/Types")
local Windows = require("../src/Core/Constants/Windows")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local SPAN = Windows.FOLD_SPAN
local PERIOD = Game.NOW // SPAN
local NOW = PERIOD * SPAN + 1000
local Cause = Book.Cause

local function Event(Name: string, Stamp: number, Amount: number, Kind: number?): Book.Event
	local Named = Kind == Cause.Returned
	return {
		Cause = Kind or Cause.Reset,
		Name = `{Name}-a-name-long-enough`,
		Stamp = Stamp,
		Amounts = { Amount },
		Ref = if Named then { Store = "Gold", Key = "d" } else nil,
	}
end

local function Holding(Events: { Book.Event }, Slots: { Book.Slot }?): Book.Book
	local Record = Book.New()
	Record.Events = Events
	Record.Slots = Slots or {}
	return Record
end

local function Room(Events: { Book.Event }, Clock: number): Types.Build
	return Game.Build({ LossRoom = Book.LossWidth(Events, {}, Clock) - 1 })
end

local function Names(Record: Book.Book): string
	local Found: { string } = {}
	for _, Each in Record.Events do
		table.insert(Found, (string.gsub(Each.Name, "%-a%-name%-long%-enough", "")))
	end
	table.sort(Found)
	return table.concat(Found, " ")
end

local function Folded(Record: Book.Book, Period: number): (number, number)
	for _, Slot in Record.Slots do
		if Slot.Period == Period then
			local Sum = Slot.Sums[1]
			return Slot.Count, if Sum then Sum.High * Alphabet.LIMB + Sum.Low else 0
		end
	end
	return 0, 0
end

Describe("Losses", function()
	Test("the event with the least stamp folds first, and the others stay whole", function()
		local First, Second, Third = Event("e1", NOW - 30, 1), Event("e2", NOW - 20, 10), Event("e3", NOW, 100)
		local Record = Holding({ Second, First })
		Expect(Losses.Name(Record, Room({ First, Second, Third }, NOW), NOW, NOW, Third)).toBeNil()
		Expect(Names(Record)).toBe("e2 e3")
		local Count, Sum = Folded(Record, PERIOD)
		Expect(Count).toBe(1)
		Expect(Sum).toBe(1)
	end)

	Test("the new event is tried last, even when its stamp is older than one the room holds", function()
		local Held, New = Event("e1", NOW - 10, 1), Event("e2", NOW - 20, 10)
		local Record = Holding({ Held })
		Expect(Losses.Name(Record, Room({ Held, New }, NOW), NOW, NOW, New)).toBeNil()
		Expect(Names(Record)).toBe("e2")
		local Count, Sum = Folded(Record, PERIOD)
		Expect(Count).toBe(1)
		Expect(Sum).toBe(1)
	end)

	Test("an event whose period ended two periods ago is removed and not folded", function()
		local Late = (PERIOD + 2) * SPAN
		local Old, New = Event("e1", NOW, 1), Event("e2", Late, 10)
		local Record = Holding({ Old })
		Expect(Losses.Name(Record, Room({ Old, New }, Late), Late, Late, New)).toBeNil()
		Expect(Names(Record)).toBe("e2")
		Expect(#Record.Slots).toBe(0)
	end)

	Test("an event that wants a third slot does not fold, and the cut waits for the first slot to end", function()
		local Clock = (PERIOD + 1) * SPAN + 5
		local Old, New = Event("e1", NOW, 1), Event("e2", Clock, 10)
		local Slots: { Book.Slot } = {
			{ Period = PERIOD + 1, Count = 1, Sums = { { High = 0, Low = 3 } } },
			{ Period = PERIOD + 2, Count = 1, Sums = { { High = 0, Low = 4 } } },
		}
		local Record = Holding({ Old }, Slots)
		local Wait = Losses.Name(Record, Game.Build({ LossRoom = 0 }), Clock, Clock, New)
		Expect(Names(Record)).toBe("e1")
		Expect(#Record.Slots).toBe(2)
		Expect(Wait).toBe((PERIOD + 3) * SPAN)
		local Count, Sum = Folded(Record, PERIOD + 1)
		Expect(Count).toBe(2)
		Expect(Sum).toBe(13)
	end)

	Test("a named return never folds, and stays whole while another event can fold", function()
		local First, Second = Event("r1", NOW - 50, 1, Cause.Returned), Event("r2", NOW - 40, 10, Cause.Returned)
		local Cut = Event("e3", NOW, 100)
		local Record = Holding({ First, Second })
		Expect(Losses.Name(Record, Room({ First, Second, Cut }, NOW), NOW, NOW, Cut)).toBeNil()
		Expect(Names(Record)).toBe("r1 r2")
		local Count, Sum = Folded(Record, PERIOD)
		Expect(Count).toBe(1)
		Expect(Sum).toBe(100)
	end)

	Test("when nothing can fold, the oldest named return goes", function()
		local Returns: { Book.Event } = {}
		for Index = 1, 3 do
			table.insert(Returns, Event(`r{Index}`, NOW - 60 + Index * 10, Index, Cause.Returned))
		end
		local Newest = Event("r4", NOW - 20, 4, Cause.Returned)
		local Record = Holding({ Returns[2], Returns[1], Returns[3] })
		local All = table.clone(Returns)
		table.insert(All, Newest)
		Expect(Losses.Name(Record, Room(All, NOW), NOW, NOW, Newest)).toBeNil()
		Expect(Names(Record)).toBe("r2 r3 r4")
		Expect(#Record.Slots).toBe(0)
	end)

	Test("an event leaves once the clock reads KeepNamed past its stamp, and a slot once its two periods are over", function()
		local Build = Game.DEFAULT
		local Record = Holding({ Event("e1", NOW - Build.KeepNamed, 1), Event("e2", NOW - Build.KeepNamed + 1, 10) }, {
			{ Period = PERIOD - 2, Count = 1, Sums = {} },
			{ Period = PERIOD - 1, Count = 1, Sums = {} },
		})
		Expect(Losses.Age(Record, Build, NOW)).toBe(true)
		Expect(Names(Record)).toBe("e2")
		Expect(#Record.Slots).toBe(1)
		Expect(Record.Slots[1].Period).toBe(PERIOD - 1)
		Expect(Losses.Age(Record, Build, NOW)).toBe(false)
	end)

	Test("a sum past one limb carries into the high limb and stays exact", function()
		local Sum: Book.Sum = { High = 0, Low = 0 }
		Losses.AddToSum(Sum, Alphabet.LIMB - 1)
		Losses.AddToSum(Sum, Alphabet.LIMB - 1)
		Expect(Sum.High).toBe(1)
		Expect(Sum.Low).toBe(Alphabet.LIMB - 2)
	end)
end)

return nil
