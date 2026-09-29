--!strict
--!optimize 2

--[=[

	Book: The record's bookkeeping, as a table and as the text a key stores in its b field.

	The text is the fixed fields, then each room as a count of 3 characters and its items. Room
	stamps are stored as their signed distance from the clock of the write, which Encode is handed,
	and the two horizons whole. A writer entry is its writer's id, lo, newest stamp, and the fates not
	took above the last ack, each as its distance below lo.

	A named entry starts with one character that holds its fate, a final fence being a fate of its
	own, whether its name is base64, whether the game chose the name, and whether a decider value
	follows. Then come its kind, its name, its stamp, the attempt of a fence or an abort, the
	fingerprint of a game's name, and the value. A name Ledger drew is stored as its server number
	and counter, and held in memory behind DRAWN, a byte no utf8 name starts with, so a drawn name and
	a game's name never meet. Decode refuses any text Encode does not write. Fate names the codes a
	fate is stored as. Version reads the format of a text without decoding it, so a newer book can be
	told from a broken one. EntryWidth and NamedWidth give the characters one item takes, from the
	same code that writes it.

	Return type: A table with New, Encode, Decode, Drawn, Version, EntryWidth, NamedWidth, Fate, FORMAT
	and DRAWN.
	Example usage:
		local Book = require("./Book")
		local Record = Book.New()
		local Text = Book.Encode(Record, Now)
		local Again = Book.Decode(Text)
--]=]

local Reader = require("../Encode/Reader")
local Writer = require("../Encode/Writer")

export type Fate = number

export type Entry = {
	Id: number,
	Lo: number,
	Stamp: number,
	Fates: { [number]: Fate },
}

export type Named = {
	Kind: number,
	Stamp: number,
	Fate: Fate,
	Attempt: number?,
	Final: boolean?,
	Print: number?,
	Value: number?,
}

export type Book = {
	Format: number,
	Level: number,
	Floor: number,
	Writes: number,
	Cuts: number,
	Id: string?,
	Horizon: number,
	CutHorizon: number,
	Writers: { [number]: Entry },
	Timed: { [string]: Named },
	Cut: { [string]: Named },
	Untimed: { [string]: Named },
}

local FORMAT = 1
local DRAWN = "\255"
local COUNT_WIDTH = 3

local Fate = table.freeze({
	Took = 0,
	Refused = 1,
	Full = 2,
	Fenced = 3,
	Aborted = 4,
	Turned = 5,
})

local FENCED_FINAL = 6
local BASE64 = 8
local GAME = 16
local VALUE = 32

local function New(): Book
	return {
		Format = FORMAT,
		Level = 0,
		Floor = 0,
		Writes = 0,
		Cuts = 0,
		Id = nil,
		Horizon = 0,
		CutHorizon = 0,
		Writers = {},
		Timed = {},
		Cut = {},
		Untimed = {},
	}
end

local function Drawn(Server: number, Counter: number): string
	local Text = Writer.New()
	Writer.Var(Text, Server)
	Writer.Var(Text, Counter)
	return `{DRAWN}{Writer.Finish(Text)}`
end

local function PutNamed(Text: Writer.Writer, Name: string, Item: Named, Now: number)
	local Game = Item.Print ~= nil
	if Game == (string.sub(Name, 1, 1) == DRAWN) then
		error(`Book: the name {Name} and its fingerprint disagree about who chose it`, 0)
	end
	if Item.Final and Item.Fate ~= Fate.Fenced then
		error(`Book: only a fence is final, and {Name} is not fenced`, 0)
	end
	local At = Writer.Fixed(Text, 0, 1)
	Writer.Var(Text, Item.Kind)
	local Base64 = Writer.Label(Text, if Game then Name else string.sub(Name, 2))
	local Head = if Item.Final then FENCED_FINAL else Item.Fate
	if Base64 then
		Head += BASE64
	end
	if Game then
		Head += GAME
	end
	if Item.Value then
		Head += VALUE
	end
	Writer.Patch(Text, At, Head, 1)
	Writer.Signed(Text, Item.Stamp - Now)
	if Item.Fate == Fate.Fenced or Item.Fate == Fate.Aborted then
		Writer.Var(Text, Item.Attempt or 0)
	end
	if Item.Print then
		Writer.Fixed(Text, Item.Print, 3)
	end
	if Item.Value then
		Writer.Var(Text, Item.Value)
	end
end

local function PutEntry(Text: Writer.Writer, Found: Entry, Now: number)
	Writer.Var(Text, Found.Id)
	Writer.Var(Text, Found.Lo)
	Writer.Signed(Text, Found.Stamp - Now)
	local Held = 0
	for _ in Found.Fates do
		Held += 1
	end
	Writer.Var(Text, Held)
	for Seq, Code in Found.Fates do
		Writer.Var(Text, Found.Lo - Seq)
		Writer.Fixed(Text, Code, 1)
	end
end

local Scratch = Writer.New()

local function EntryWidth(Found: Entry, Now: number): number
	Writer.Clear(Scratch)
	PutEntry(Scratch, Found, Now)
	return Scratch.Cursor
end

local function NamedWidth(Name: string, Item: Named, Now: number): number
	Writer.Clear(Scratch)
	PutNamed(Scratch, Name, Item, Now)
	return Scratch.Cursor
end

local function PutRoom(Text: Writer.Writer, Room: { [string]: Named }, Now: number)
	local At = Writer.Fixed(Text, 0, COUNT_WIDTH)
	local Count = 0
	for Name, Item in Room do
		PutNamed(Text, Name, Item, Now)
		Count += 1
	end
	Writer.Patch(Text, At, Count, COUNT_WIDTH)
end

local function Encode(Record: Book, Now: number): string
	local Text = Writer.New()
	Writer.Fixed(Text, Record.Format, 1)
	Writer.Fixed(Text, if Record.Id then 1 else 0, 1)
	Writer.Var(Text, Record.Level)
	Writer.Var(Text, Record.Floor)
	Writer.Var(Text, Record.Writes)
	Writer.Var(Text, Record.Cuts)
	if Record.Id then
		Writer.Name(Text, Record.Id)
	end
	Writer.Var(Text, Now)
	Writer.Var(Text, Record.Horizon)
	Writer.Var(Text, Record.CutHorizon)

	local At = Writer.Fixed(Text, 0, COUNT_WIDTH)
	local Count = 0
	for _, Found in Record.Writers do
		PutEntry(Text, Found, Now)
		Count += 1
	end
	Writer.Patch(Text, At, Count, COUNT_WIDTH)

	PutRoom(Text, Record.Timed, Now)
	PutRoom(Text, Record.Cut, Now)
	PutRoom(Text, Record.Untimed, Now)
	return Writer.Finish(Text)
end

local function TakeFate(Code: number): Fate
	if Code > Fate.Turned then
		error(`Book: {Code} is not a fate`, 0)
	end
	return Code
end

local function TakeRoom(Text: Reader.Reader, Now: number): { [string]: Named }
	local Room: { [string]: Named } = {}
	for _ = 1, Reader.Fixed(Text, COUNT_WIDTH) do
		local Head = Reader.Fixed(Text, 1)
		local Final = Head % BASE64 == FENCED_FINAL
		local Code = if Final then Fate.Fenced else TakeFate(Head % BASE64)
		local Kind = Reader.Var(Text)
		local Name = Reader.Label(Text, bit32.btest(Head, BASE64))
		local Item: Named = { Kind = Kind, Stamp = Now + Reader.Signed(Text), Fate = Code }
		if Code == Fate.Fenced or Code == Fate.Aborted then
			Item.Attempt = Reader.Var(Text)
		end
		if Final then
			Item.Final = true
		end
		if bit32.btest(Head, GAME) then
			Item.Print = Reader.Fixed(Text, 3)
		else
			Name = `{DRAWN}{Name}`
		end
		if bit32.btest(Head, VALUE) then
			Item.Value = Reader.Var(Text)
		end
		if Room[Name] then
			error("Book: a room holds one name twice", 0)
		end
		Room[Name] = Item
	end
	return Room
end

local function Take(Source: string): Book
	local Text = Reader.New(Source)
	local Record = New()
	Record.Format = Reader.Fixed(Text, 1)
	if Record.Format ~= FORMAT then
		error(`Book: format {Record.Format} is not one this build reads`, 0)
	end
	local Flags = Reader.Fixed(Text, 1)
	if Flags > 1 then
		error(`Book: flags {Flags} are not ones this build writes`, 0)
	end
	Record.Level = Reader.Var(Text)
	Record.Floor = Reader.Var(Text)
	Record.Writes = Reader.Var(Text)
	Record.Cuts = Reader.Var(Text)
	if Flags == 1 then
		Record.Id = Reader.Name(Text)
	end
	local Now = Reader.Var(Text)
	Record.Horizon = Reader.Var(Text)
	Record.CutHorizon = Reader.Var(Text)

	for _ = 1, Reader.Fixed(Text, COUNT_WIDTH) do
		local Found: Entry = { Id = Reader.Var(Text), Lo = Reader.Var(Text), Stamp = 0, Fates = {} }
		Found.Stamp = Now + Reader.Signed(Text)
		for _ = 1, Reader.Var(Text) do
			local Seq = Found.Lo - Reader.Var(Text)
			Found.Fates[Seq] = TakeFate(Reader.Fixed(Text, 1))
		end
		if Record.Writers[Found.Id] then
			error("Book: two entries for one writer", 0)
		end
		Record.Writers[Found.Id] = Found
	end
	Record.Timed = TakeRoom(Text, Now)
	Record.Cut = TakeRoom(Text, Now)
	Record.Untimed = TakeRoom(Text, Now)
	if not Reader.Done(Text) then
		error("Book: text past the last room", 0)
	end
	return Record
end

local function Version(Source: string): number?
	local Ok, Format = pcall(Reader.Fixed, Reader.New(Source), 1)
	return if Ok then Format else nil
end

local function Decode(Source: string): (Book?, string?)
	local Ok, Result = pcall(Take, Source)
	if Ok then
		return Result, nil
	end
	return nil, tostring(Result)
end

return table.freeze({
	New = New,
	Encode = Encode,
	Decode = Decode,
	Drawn = Drawn,
	Version = Version,
	EntryWidth = EntryWidth,
	NamedWidth = NamedWidth,
	Fate = Fate,
	FORMAT = FORMAT,
	DRAWN = DRAWN,
})
