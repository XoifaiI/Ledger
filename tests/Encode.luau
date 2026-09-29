--!strict

--[=[

	Encode: The cases for Encode/Writer and Encode/Reader.

	Return type: nil. Requiring it adds its cases to the run.
	Example usage:
		zune test tests/Run.luau
--]=]

local Testing = require("./Testing")
local Alphabet = require("../src/Encode/Alphabet")
local Reader = require("../src/Encode/Reader")
local Writer = require("../src/Encode/Writer")

local Describe, Test, Expect, Similar = Testing.Describe, Testing.Test, Testing.Expect, Testing.Similar

local LIMB = Alphabet.LIMB

Describe("Encode", function()
	Test("a number takes the widths the record design states", function()
		local Widths = {
			{ 0, 1 },
			{ 31, 1 },
			{ 32, 2 },
			{ 1023, 2 },
			{ 1024, 3 },
			{ 32767, 3 },
			{ 32768, 4 },
			{ 2 ^ 20 - 1, 4 },
			{ 2 ^ 20, 5 },
			{ 2 ^ 25 - 1, 5 },
			{ 2 ^ 25, 6 },
			{ 2 ^ 30 - 1, 6 },
			{ 2 ^ 53 - 1, 11 },
		}
		for _, Pair in Widths do
			local Book = Writer.New()
			Writer.Var(Book, Pair[1])
			local Text = Writer.Finish(Book)
			Expect(Text).toHaveLength(Pair[2])
			local Read = Reader.New(Text)
			Expect(Reader.Var(Read)).toBe(Pair[1])
			Expect(Reader.Done(Read)).toBe(true)
		end
	end)

	Test("every number below 2^16 comes back exactly", function()
		local Book = Writer.New()
		for Value = 0, 65535 do
			Writer.Var(Book, Value)
		end
		local Read = Reader.New(Writer.Finish(Book))
		local Wrong = 0
		for Value = 0, 65535 do
			if Reader.Var(Read) ~= Value then
				Wrong += 1
			end
		end
		Expect(Wrong).toBe(0)
		Expect(Reader.Done(Read)).toBe(true)
	end)

	Test("a signed number comes back exactly at every size below 2^53", function()
		local Values = {
			0,
			1,
			-1,
			15,
			-16,
			16,
			-17,
			123456789,
			-987654321,
			2 ^ 52 - 1,
			-(2 ^ 52 - 1),
			2 ^ 52,
			-2 ^ 52,
			2 ^ 53 - 1,
			-(2 ^ 53 - 1),
		}
		local Book = Writer.New()
		for _, Value in Values do
			Writer.Signed(Book, Value)
		end
		local Read = Reader.New(Writer.Finish(Book))
		for _, Value in Values do
			Expect(Reader.Signed(Read)).toBe(Value)
		end
		Expect(Reader.Done(Read)).toBe(true)
	end)

	Test("a wide sum comes back exactly up to 2^80", function()
		local Sums: { { any } } = {
			{ false, 0, 0 },
			{ true, 0, 1 },
			{ true, 1, 0 },
			{ false, 1, 0 },
			{ false, 2 ^ 45 - 1, LIMB - 1 },
			{ true, 2 ^ 45 - 1, LIMB - 1 },
		}
		local Book = Writer.New()
		for _, Sum in Sums do
			Writer.Wide(Book, Sum[1], Sum[2], Sum[3])
		end
		local Read = Reader.New(Writer.Finish(Book))
		for _, Sum in Sums do
			Expect({ Reader.Wide(Read) }).toBe(Similar(Sum))
		end
		Expect(Reader.Done(Read)).toBe(true)
	end)

	Test("a negative zero is written as zero", function()
		local Book = Writer.New()
		Writer.Wide(Book, true, 0, 0)
		Writer.Signed(Book, -0)
		local Read = Reader.New(Writer.Finish(Book))
		Expect({ Reader.Wide(Read) }).toBe(Similar({ false, 0, 0 }))
		Expect(Reader.Signed(Read)).toBe(0)
	end)

	Test("a book holds only alphabet characters", function()
		local Book = Writer.New()
		Writer.Var(Book, 2 ^ 53 - 1)
		Writer.Signed(Book, -12345)
		Writer.Wide(Book, true, 2 ^ 45 - 1, LIMB - 1)
		Writer.Fixed(Book, 262143, 3)
		Writer.Name(Book, '日本 \0"\\')
		Expect((string.find(Writer.Finish(Book), "^[%w_%-]*$"))).toBe(1)
	end)

	Test("fixed writes a set width and patch rewrites it in place", function()
		local Book = Writer.New()
		local At = Writer.Fixed(Book, 0, 3)
		Writer.Var(Book, 5)
		Writer.Patch(Book, At, 262143, 3)
		local Read = Reader.New(Writer.Finish(Book))
		Expect(Reader.Fixed(Read, 3)).toBe(262143)
		Expect(Reader.Var(Read)).toBe(5)
		Expect(Reader.Done(Read)).toBe(true)
		Expect(function()
			Writer.Fixed(Book, 64, 1)
		end).toThrow("Writer: 64 does not fit in 1 characters")
		Expect(function()
			Writer.Patch(Book, 3, 1, 3)
		end).toThrow("Writer: a patch at 3 is past what was written")
	end)

	Test("a name is stored as it is when the alphabet holds it", function()
		local Book = Writer.New()
		Writer.Name(Book, "Gold")
		Writer.Name(Book, "")
		local Text = Writer.Finish(Book)
		Expect(Text).toBe("oGoldg")
		local Read = Reader.New(Text)
		Expect(Reader.Name(Read)).toBe("Gold")
		Expect(Reader.Name(Read)).toBe("")
		Expect(Reader.Done(Read)).toBe(true)
	end)

	Test("any other name comes back exactly through base64url", function()
		local Names = { "a b", "日本", "\0", "\0\1", "\0\1\2", "\0\1\2\3", "x.y@z", string.rep("é", 24) }
		local Book = Writer.New()
		for _, Name in Names do
			Writer.Name(Book, Name)
		end
		local Read = Reader.New(Writer.Finish(Book))
		for _, Name in Names do
			Expect(Reader.Name(Read)).toBe(Name)
		end
		Expect(Reader.Done(Read)).toBe(true)
	end)

	Test("the writer grows past its first size and clear reuses it", function()
		local Book = Writer.New()
		for _ = 1, 1000 do
			Writer.Var(Book, 2 ^ 53 - 1)
		end
		Writer.Name(Book, string.rep("é", 500))
		local Read = Reader.New(Writer.Finish(Book))
		for _ = 1, 1000 do
			Expect(Reader.Var(Read)).toBe(2 ^ 53 - 1)
		end
		Expect(Reader.Name(Read)).toBe(string.rep("é", 500))
		Expect(Reader.Done(Read)).toBe(true)
		Writer.Clear(Book)
		Writer.Var(Book, 1)
		Expect(Writer.Finish(Book)).toBe("h")
	end)

	Test("the writer refuses what it cannot store exactly", function()
		local Book = Writer.New()
		for _, Value in { -1, 2 ^ 53, 1.5, 0 / 0, math.huge } do
			Expect(function()
				Writer.Var(Book, Value)
			end).toThrow(`Writer: {Value} is not a whole number from 0 to 2^53 - 1`)
		end
		for _, Value in { 2 ^ 53, -2 ^ 53, 0.5 } do
			Expect(function()
				Writer.Signed(Book, Value)
			end).toThrow(`Writer: {Value} is not a whole number of size below 2^53`)
		end
		for _, Parts in { { 2 ^ 45, 0 }, { 0, LIMB } } do
			Expect(function()
				Writer.Wide(Book, false, Parts[1], Parts[2])
			end).toThrow("Writer: a wide number needs whole High below 2^45 and Low below LIMB")
		end
	end)

	Test("the reader refuses a book that is not whole or not canonical", function()
		local Books: { { any } } = {
			{ Reader.Var, "", "character 1 of the book is past the end" },
			{ Reader.Var, "A", "character 2 of the book is past the end" },
			{ Reader.Var, "=", "character 1 of the book is outside the alphabet" },
			{ Reader.Var, "A=", "character 2 of the book is outside the alphabet" },
			{ Reader.Var, "Ag", "character 2 of the book is a number that ends in a zero" },
			{ Reader.Var, string.rep("B", 17), "character 18 of the book is a number that does not end" },
			{ Reader.Var, "AAAAAAAAAAo", "character 11 of the book is a number past 2^53" },
			{ Reader.Name, "oGol", "character 5 of the book is a name past the end" },
			{ Reader.Name, "oGo=d", "character 4 of the book is outside the alphabet" },
			{ Reader.Name, "rABCDE", "character 2 of the book is a name of a length base64 never has" },
			{ Reader.Name, "nAB", "character 4 of the book is a name past the end" },
			{ Reader.Name, "lAB", "character 3 of the book is a name with bits past its last byte" },
			{ Reader.Name, "tR29sZA", "character 2 of the book is a name in base64 that needs none" },
		}
		for _, Case in Books do
			Expect(function()
				Case[1](Reader.New(Case[2]))
			end).toThrow(`Reader: {Case[3]}`)
		end
		for _, Case in { { "AB", "character 3 of the book is past the end" }, { "A=B", "character 2 of the book is outside the alphabet" } } do
			Expect(function()
				Reader.Fixed(Reader.New(Case[1]), 3)
			end).toThrow(`Reader: {Case[2]}`)
		end
	end)
end)

return nil
