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
	Record.Timed[Book.Drawn(12345, 678)] = { Kind = 0, Stamp = NOW - 20, Fate = Book.Fate.Took }
	Record.Timed[Book.Drawn(99, 1)] = { Kind = 0, Stamp = NOW - 30, Fate = Book.Fate.Fenced, Attempt = 2, Final = true }
	Record.Timed["order-1f9c2a"] = { Kind = 4, Stamp = NOW - 10, Fate = Book.Fate.Took, Print = 40000, Value = 17 }
	Record.Timed["gift for ✨"] = { Kind = 5, Stamp = NOW - 5, Fate = Book.Fate.Aborted, Attempt = 1, Print = 5 }
	Record.Cut[Book.Drawn(4, 4)] = { Kind = 1, Stamp = NOW - 60, Fate = Book.Fate.Took }
	Record.Untimed["daily-reward"] = { Kind = 6, Stamp = NOW - 70, Fate = Book.Fate.Full, Print = 65535 }
	Record.Timed[Book.Drawn(99, 2)] = { Kind = 0, Role = Book.Role.Leg, Stamp = NOW - 3, Fate = Book.Fate.Took, Attempt = 2 }
	Record.Timed["trade-9"] = { Kind = 0, Role = Book.Role.Decision, Stamp = NOW - 4, Fate = Book.Fate.Refused, Attempt = 1, Print = 12 }
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
		Named.Timed[Book.Drawn(1_048_577, 20000)] = { Kind = 0, Stamp = NOW + 200, Fate = Book.Fate.Took }
		Expect(Width(Named) - Empty).toBe(13)

		local Game = Book.New()
		Game.Writes = 5000
		Game.Writers[2] = Base.Writers[2]
		Game.Timed["abcdefghijklmnop"] = { Kind = 3, Stamp = NOW + 200, Fate = Book.Fate.Took, Print = 1 }
		Expect(Width(Game) - Empty).toBe(24)
	end)

	Test("a drawn name and a game's name with the same text are two names", function()
		local Record = Book.New()
		local Drawn = Book.Drawn(5, 6)
		local Plain = string.sub(Drawn, 2)
		Record.Timed[Drawn] = { Kind = 0, Stamp = NOW, Fate = Book.Fate.Took }
		Record.Timed[Plain] = { Kind = 0, Stamp = NOW, Fate = Book.Fate.Refused, Print = 9 }
		local Back = Book.Decode(Record:Encode(NOW)) :: Book.Book
		Expect(Back.Timed[Drawn].Fate).toBe(Book.Fate.Took)
		Expect(Back.Timed[Plain].Fate).toBe(Book.Fate.Refused)
	end)

	Test("a text Encode would not write is refused", function()
		local Text = Full():Encode(NOW)
		for _, Bad in { "", "B", `{Text}A`, string.sub(Text, 1, -2), `C{string.sub(Text, 2)}`, `{Text}=` } do
			Expect(Book.Decode(Bad)).toBeNil()
		end
	end)
end)

return nil
