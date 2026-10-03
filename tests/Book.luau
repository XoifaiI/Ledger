--!strict

--[=[

	Book: The cases for Record/Book.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Book = require("../src/Record/Book")
local Canon = require("../src/Encode/Canon")

local Describe, Test, Expect = Testing.Describe, Testing.Test, Testing.Expect

local NOW = 26_000_000

local function Full(): Book.Book
	local Record = Book.New()
	Record.Level, Record.Floor, Record.Writes, Record.Cuts = 3, 2, 91234, 1
	Record.Id = "Ab3xG"
	Record.Horizon, Record.CutHorizon = NOW - 400, NOW - 900
	Record.Writers[1_048_577] = { Id = 1_048_577, Lo = 1000, Stamp = NOW, Fates = { [998] = Book.Fate.Refused, [999] = Book.Fate.Turned } }
	Record.Writers[7] = { Id = 7, Lo = 3, Stamp = NOW - 50, Fates = {} }
	Record.Timed[Book.Drawn(12345, 678)] = Book.OpName(NOW - 20, nil, Book.Fate.Took, 0)
	Record.Timed[Book.Drawn(99, 1)] = { Role = Book.Role.Op, Kind = 0, Stamp = NOW - 30, Fate = Book.Fate.Fenced, Attempt = 2 }
	Record.Timed["order-1f9c2a"] = Book.OpName(NOW - 10, 40000, Book.Fate.Took, 4)
	Record.Timed["gift for ✨"] = { Role = Book.Role.Op, Kind = 5, Stamp = NOW - 5, Fate = Book.Fate.Aborted, Attempt = 1, Print = 5 }
	Record.Cut[Book.Drawn(4, 4)] = Book.OpName(NOW - 60, nil, Book.Fate.Took, 1)
	Record.Untimed["daily-reward"] = Book.OpName(NOW - 70, 65535, Book.Fate.Full, 6)
	Record.Timed[Book.Drawn(99, 2)] = Book.LegFate(NOW - 3, nil, Book.Fate.Took, 2)
	Record.Timed["trade-9"] = Book.Decision(NOW - 4, 12, Book.Fate.Refused, 1)
	Record.Work[Book.Drawn(3, 1)] = {
		Form = "Escrow",
		Stamp = NOW - 2,
		Attempt = 1,
		Clean = true,
		Decider = { Store = "Gold", Key = "user:42" },
		Field = 3,
		Amount = -(2 ^ 53 - 1),
	}
	Record.Work["swap ✨"] = { Form = "Exclusive", Stamp = NOW, Attempt = 3, Print = 9, Clean = false, Decider = { Store = "Shop", Key = "7" } }
	Record.Work[Book.Drawn(5, 5)] = {
		Form = "Pinned",
		Stamp = NOW - 1,
		Attempt = 2,
		Legs = { { Store = "Gold", Key = "1" }, { Store = "Other store", Key = "k" } },
		Value = 42,
	}
	Record.Gate = { Name = "season-reset", Stamp = NOW - 7, Kind = Book.Cause.Reset, Print = 77, At = NOW - 6 }
	Record.Events = {
		{ Cause = Book.Cause.Reset, Name = Book.Drawn(4, 9), Stamp = NOW - 100, Amounts = { [1] = 250, [3] = -(2 ^ 53 - 1) } },
		{ Cause = Book.Cause.Returned, Name = "trade ✨", Stamp = NOW - 90, Amounts = { [2] = -40 }, Ref = { Store = "Gold", Key = "d" } },
		{ Cause = Book.Cause.Orphan, Name = Book.Drawn(8, 1), Stamp = NOW - 80, Amounts = {}, Ref = { Store = "Gold", Key = "a" } },
	}
	Record.Slots = {
		{ Period = 3, Count = 12, Sums = { [1] = { High = 4, Low = 17 }, [2] = { High = -2, Low = 5 } } },
		{ Period = 4, Count = 1, Sums = { [1] = { High = -1, Low = 0 } } },
	}
	return Record
end

local function Width(Record: Book.Book): number
	return #Record:Encode(NOW)
end

Describe("Book", function()
	Test("a book comes back exactly from its text", function()
		local Record = Full()
		local Back = Book.Decode(Record:Encode(NOW))
		Expect(Canon(Back)).toBe(Canon(Record))
		Expect(Canon(Book.Decode(Book.New():Encode(NOW)))).toBe(Canon(Book.New()))
	end)

	Test("its text is only alphabet characters", function()
		Expect((string.find(Full():Encode(NOW), "^[%w_%-]*$"))).toBe(1)
	end)

	Test("items keep their widths on a busy key: 11, 13 and 24 against the design's 12, 14 and 24", function()
		local Base = Book.New()
		Base.Writes = 5000
		Base.Writers[2] = { Id = 2, Lo = 1, Stamp = NOW, Fates = {} }
		local Empty = Width(Base)

		local Entry = Book.New()
		Entry.Writes = 5000
		Entry.Writers[2] = Base.Writers[2]
		Entry.Writers[1_048_577] = { Id = 1_048_577, Lo = 20000, Stamp = NOW + 200, Fates = {} }
		Expect(Width(Entry) - Empty).toBe(11)

		local Named = Book.New()
		Named.Writes = 5000
		Named.Writers[2] = Base.Writers[2]
		Named.Timed[Book.Drawn(1_048_577, 20000)] = Book.OpName(NOW + 200, nil, Book.Fate.Took, 0)
		Expect(Width(Named) - Empty).toBe(13)

		local Game = Book.New()
		Game.Writes = 5000
		Game.Writers[2] = Base.Writers[2]
		Game.Timed["abcdefghijklmnop"] = Book.OpName(NOW + 200, 1, Book.Fate.Took, 3)
		Expect(Width(Game) - Empty).toBe(24)
	end)

	Test("a drawn name and a game's name with the same text are two names", function()
		local Record = Book.New()
		local Drawn = Book.Drawn(5, 6)
		local Plain = string.sub(Drawn, 2)
		Record.Timed[Drawn] = Book.OpName(NOW, nil, Book.Fate.Took, 0)
		Record.Timed[Plain] = Book.OpName(NOW, 9, Book.Fate.Refused, 0)
		local Back = Book.Decode(Record:Encode(NOW)) :: Book.Book
		Expect(Back.Timed[Drawn].Fate).toBe(Book.Fate.Took)
		Expect(Back.Timed[Plain].Fate).toBe(Book.Fate.Refused)
	end)

	Test("a seal comes back exactly from its text, and a text EncodeSeal would not write is refused", function()
		local Seal: Book.Seal = {
			Name = "erase-42",
			Stamp = NOW - 3,
			Print = 1234,
			Server = 1_048_577,
			Rt = NOW,
			Events = { { Cause = Book.Cause.Erase, Name = "erase-42", Stamp = NOW, Amounts = { [1] = 99 } } },
			Slots = { { Period = 2, Count = 3, Sums = { [1] = { High = 0, Low = 7 } } } },
		}
		local Text = Book.EncodeSeal(Seal)
		Expect(Canon(Book.DecodeSeal(Text))).toBe(Canon(Seal))
		Expect(Book.DecodeSeal(Text .. "A")).toBeNil()
		Expect(Book.DecodeSeal(Full():Encode(NOW))).toBeNil()
	end)

	Test("a text Encode would not write is refused", function()
		local Text = Full():Encode(NOW)
		for _, Bad in { "", "B", `{Text}A`, string.sub(Text, 1, -2), `C{string.sub(Text, 2)}`, `{Text}=` } do
			Expect(Book.Decode(Bad)).toBeNil()
		end
	end)

	Test("a leg fate or a decision in the untimed or cut room is refused, since those rooms hold op names", function()
		for _, Room in { "Untimed", "Cut" } do
			local Record = Book.New();
			(Record :: any)[Room]["trade-9"] = Book.Decision(NOW - 4, 12, Book.Fate.Refused, 1)
			Expect(Book.Decode(Record:Encode(NOW))).toBeNil()
		end
		local Kept = Book.New()
		Kept.Untimed["daily-reward"] = Book.OpName(NOW - 70, 65535, Book.Fate.Full, 6)
		Expect(Book.Decode(Kept:Encode(NOW))).never.toBeNil()
	end)
end)

return nil
