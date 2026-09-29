--!strict

--[=[

	Parts: Times each encoding primitive on its own under the Luau CLI.

	Return type: Nothing. It prints the time per call for each primitive.
	Example usage:
		luau.exe -O2 --codegen bench/Parts.luau
--]=]

local Reader = require("../src/Encode/Reader")
local Writer = require("../src/Encode/Writer")

type Book = Writer.Writer
type Read = Reader.Reader

local COUNT = 1000000

local function Pair(Label: string, Write: (Book: Book) -> (), Take: (Book: Read) -> ())
	local Book = Writer.New()
	Write(Book)
	Writer.Clear(Book)
	local Start = os.clock()
	Write(Book)
	local Wrote = os.clock() - Start
	local Text = Writer.Finish(Book)
	Take(Reader.New(Text))
	local Read = Reader.New(Text)
	Start = os.clock()
	Take(Read)
	local Took = os.clock() - Start
	assert(Reader.Done(Read), Label)
	print(string.format("%-18s write %6.1f ns   read %6.1f ns", Label, Wrote / COUNT * 1e9, Took / COUNT * 1e9))
end

local function Vars(Label: string, Value: (Index: number) -> number)
	Pair(Label, function(Book)
		for Index = 1, COUNT do
			Writer.Var(Book, Value(Index))
		end
	end, function(Book)
		for _ = 1, COUNT do
			Reader.Var(Book)
		end
	end)
end

Vars("var below 32", function(Index)
	return Index % 32
end)
Vars("var below 2^15", function(Index)
	return Index % 32768
end)
Vars("var near 2^53", function(Index)
	return 2 ^ 53 - Index
end)
Pair("signed below 2^20", function(Book)
	for Index = 1, COUNT do
		Writer.Signed(Book, (Index % 2 * 2 - 1) * Index)
	end
end, function(Book)
	for _ = 1, COUNT do
		Reader.Signed(Book)
	end
end)
Pair("fixed of 3", function(Book)
	for Index = 1, COUNT do
		Writer.Fixed(Book, Index % 262144, 3)
	end
end, function(Book)
	for _ = 1, COUNT do
		Reader.Fixed(Book, 3)
	end
end)
Pair("name of 16 raw", function(Book)
	for _ = 1, COUNT do
		Writer.Name(Book, "G000000000012345")
	end
end, function(Book)
	for _ = 1, COUNT do
		Reader.Name(Book)
	end
end)
Pair("name of 12 base64", function(Book)
	for _ = 1, COUNT do
		Writer.Name(Book, "player 12345")
	end
end, function(Book)
	for _ = 1, COUNT do
		Reader.Name(Book)
	end
end)
