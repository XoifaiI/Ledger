--!strict
--!optimize 2

--[=[

	Book: Logic. The record's bookkeeping, as an object and as the text in a key's b field.

	Spec: record 2.2 and 2.3; transaction 2.

	The text holds the fixed fields, then each room as a count and its items. Room stamps are stored
	as offsets from the clock of the write. A drawn name is held behind DRAWN and stored as its server
	number and counter. A named entry has a role: an op's name, a leg's fate or a decision, stored
	with its kind. The work room holds escrow marks, exclusive marks and pinned records by name. Decode
	refuses any text Encode does not write, and gives back nil for it. Version reads only the format.
	EntryWidth, NamedWidth and WorkWidth give the width of one item.

	Return type: The Book class, with New, Decode, Drawn, Version, EntryWidth, NamedWidth, WorkWidth,
	Fate, Role, FORMAT and DRAWN, and the methods Held and Encode. The types are Entry, Named, Ref,
	Escrow, Exclusive, Pinned and Work.
	Example usage:
		local Again = Book.Decode(Record:Encode(Now))
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
	Role: number?,
	Stamp: number,
	Fate: Fate,
	Attempt: number?,
	Final: boolean?,
	Print: number?,
	Value: number?,
}

export type Ref = {
	read Store: string,
	read Key: string,
}

export type Escrow = {
	read Form: "Escrow",
	read Stamp: number,
	read Attempt: number,
	read Print: number?,
	Clean: boolean,
	read Decider: Ref,
	read Field: number,
	read Amount: number,
}

export type Exclusive = {
	read Form: "Exclusive",
	read Stamp: number,
	read Attempt: number,
	read Print: number?,
	Clean: boolean,
	read Decider: Ref,
}

export type Pinned = {
	read Form: "Pinned",
	read Stamp: number,
	read Attempt: number,
	read Print: number?,
	read Legs: { Ref },
	read Value: number?,
}

export type Work = Escrow | Exclusive | Pinned

type BookImpl = {
	__index: BookImpl,
	Held: (self: Book, Name: string) -> Named?,
	New: () -> Book,
	Decode: (Source: string) -> Book?,
	Version: (Source: string) -> number?,
	Drawn: (Server: number, Counter: number) -> string,
	EntryWidth: (Found: Entry, Now: number) -> number,
	NamedWidth: (Name: string, Item: Named, Now: number) -> number,
	WorkWidth: (Name: string, Item: Work, Now: number) -> number,
	Fate: { read Took: number, read Refused: number, read Full: number, read Fenced: number, read Aborted: number, read Turned: number },
	Role: { read Op: number, read Leg: number, read Decision: number },
	FORMAT: number,
	DRAWN: string,
	Encode: (self: Book, Now: number) -> string,
}

type Data = {
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
	Work: { [string]: Work },
}

export type Book = setmetatable<Data, BookImpl>

local FORMAT = 1
local DRAWN = "\255"
local COUNT_WIDTH = 3

local Fate = {
	Took = 0,
	Refused = 1,
	Full = 2,
	Fenced = 3,
	Aborted = 4,
	Turned = 5,
}

local Role = {
	Op = 0,
	Leg = 1,
	Decision = 2,
}

local ROLES = 3
local FENCED_FINAL = 6
local BASE64 = 8
local GAME = 16
local VALUE = 32
local CLEAN = 4
local FORMS = 4
local ESCROW = 0
local EXCLUSIVE = 1
local PINNED = 2

local Book = {} :: BookImpl
Book.__index = Book

local function PutNamed(Text: Writer.Writer, Name: string, Item: Named, Now: number)
	local Game = Item.Print ~= nil
	if Game == (string.sub(Name, 1, 1) == DRAWN) then
		error(`Book: the name {Name} and its fingerprint disagree about who chose it`, 0)
	end
	if Item.Final and Item.Fate ~= Fate.Fenced then
		error(`Book: only a fence is final, and {Name} is not fenced`, 0)
	end
	local At = Writer.Fixed(Text, 0, 1)
	Writer.Var(Text, Item.Kind * ROLES + (Item.Role or Role.Op))
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
	if (Item.Role or Role.Op) ~= Role.Op or Item.Fate == Fate.Fenced or Item.Fate == Fate.Aborted then
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

local function PutRoom(Text: Writer.Writer, Room: { [string]: Named }, Now: number)
	local At = Writer.Fixed(Text, 0, COUNT_WIDTH)
	local Count = 0
	for Name, Item in Room do
		PutNamed(Text, Name, Item, Now)
		Count += 1
	end
	Writer.Patch(Text, At, Count, COUNT_WIDTH)
end

local function PutRef(Text: Writer.Writer, Held: Ref)
	Writer.Name(Text, Held.Store)
	Writer.Name(Text, Held.Key)
end

local function PutWork(Text: Writer.Writer, Name: string, Item: Work, Now: number)
	local Game = Item.Print ~= nil
	if Game == (string.sub(Name, 1, 1) == DRAWN) then
		error(`Book: the name {Name} and its fingerprint disagree about who chose it`, 0)
	elseif Item.Attempt < 1 then
		error(`Book: {Name} has no attempt`, 0)
	end
	local At = Writer.Fixed(Text, 0, 1)
	local Base64 = Writer.Label(Text, if Game then Name else string.sub(Name, 2))
	Writer.Signed(Text, Item.Stamp - Now)
	Writer.Var(Text, Item.Attempt)
	if Item.Print then
		Writer.Fixed(Text, Item.Print, 3)
	end
	local Head = if Base64 then BASE64 else 0
	if Game then
		Head += GAME
	end
	if Item.Form == "Pinned" then
		Head += PINNED
		Writer.Var(Text, #Item.Legs)
		for _, Leg in Item.Legs do
			PutRef(Text, Leg)
		end
		if Item.Value then
			Head += VALUE
			Writer.Var(Text, Item.Value)
		end
	else
		Head += if Item.Form == "Escrow" then ESCROW else EXCLUSIVE
		if Item.Clean then
			Head += CLEAN
		end
		PutRef(Text, Item.Decider)
		if Item.Form == "Escrow" then
			Writer.Var(Text, Item.Field)
			Writer.Signed(Text, Item.Amount)
		end
	end
	Writer.Patch(Text, At, Head, 1)
end

local function PutWorkRoom(Text: Writer.Writer, Room: { [string]: Work }, Now: number)
	local At = Writer.Fixed(Text, 0, COUNT_WIDTH)
	local Count = 0
	for Name, Item in Room do
		PutWork(Text, Name, Item, Now)
		Count += 1
	end
	Writer.Patch(Text, At, Count, COUNT_WIDTH)
end

local Scratch = Writer.New()

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
		local Item: Named = { Kind = Kind // ROLES, Stamp = Now + Reader.Signed(Text), Fate = Code }
		if Kind % ROLES ~= Role.Op then
			Item.Role = Kind % ROLES
		end
		if Item.Role or Code == Fate.Fenced or Code == Fate.Aborted then
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

local function TakeRef(Text: Reader.Reader): Ref
	local Store = Reader.Name(Text)
	return { Store = Store, Key = Reader.Name(Text) }
end

local function TakeWork(Text: Reader.Reader, Now: number): { [string]: Work }
	local Room: { [string]: Work } = {}
	for _ = 1, Reader.Fixed(Text, COUNT_WIDTH) do
		local Head = Reader.Fixed(Text, 1)
		local Form = Head % FORMS
		local Name = Reader.Label(Text, bit32.btest(Head, BASE64))
		local Stamp = Now + Reader.Signed(Text)
		local Attempt = Reader.Var(Text)
		local Print = if bit32.btest(Head, GAME) then Reader.Fixed(Text, 3) else nil
		if Print == nil then
			Name = `{DRAWN}{Name}`
		end
		if Attempt < 1 or Room[Name] then
			error("Book: a work item with no attempt, or one name twice", 0)
		end
		local Clean = bit32.btest(Head, CLEAN)
		if Form == PINNED and not Clean then
			local Legs: { Ref } = {}
			for Index = 1, Reader.Var(Text) do
				Legs[Index] = TakeRef(Text)
			end
			local Value = if bit32.btest(Head, VALUE) then Reader.Var(Text) else nil
			Room[Name] = { Form = "Pinned", Stamp = Stamp, Attempt = Attempt, Print = Print, Legs = Legs, Value = Value }
		elseif Form == ESCROW and not bit32.btest(Head, VALUE) then
			local Decider = TakeRef(Text)
			local Field = Reader.Var(Text)
			Room[Name] = {
				Form = "Escrow",
				Stamp = Stamp,
				Attempt = Attempt,
				Print = Print,
				Clean = Clean,
				Decider = Decider,
				Field = Field,
				Amount = Reader.Signed(Text),
			}
		elseif Form == EXCLUSIVE and not bit32.btest(Head, VALUE) then
			local Decider = TakeRef(Text)
			Room[Name] = { Form = "Exclusive", Stamp = Stamp, Attempt = Attempt, Print = Print, Clean = Clean, Decider = Decider }
		else
			error(`Book: {Head} is not the head of a work item`, 0)
		end
	end
	return Room
end

local function TakeWriters(Text: Reader.Reader, Now: number): { [number]: Entry }
	local Writers: { [number]: Entry } = {}
	for _ = 1, Reader.Fixed(Text, COUNT_WIDTH) do
		local Found: Entry = { Id = Reader.Var(Text), Lo = Reader.Var(Text), Stamp = 0, Fates = {} }
		Found.Stamp = Now + Reader.Signed(Text)
		for _ = 1, Reader.Var(Text) do
			local Seq = Found.Lo - Reader.Var(Text)
			Found.Fates[Seq] = TakeFate(Reader.Fixed(Text, 1))
		end
		if Writers[Found.Id] then
			error("Book: two entries for one writer", 0)
		end
		Writers[Found.Id] = Found
	end
	return Writers
end

local function Take(Source: string): Book
	local Text = Reader.New(Source)
	local Record = Book.New()
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
	Record.Writers = TakeWriters(Text, Now)
	Record.Timed = TakeRoom(Text, Now)
	Record.Cut = TakeRoom(Text, Now)
	Record.Untimed = TakeRoom(Text, Now)
	Record.Work = TakeWork(Text, Now)
	if not Reader.Done(Text) then
		error("Book: text past the last room", 0)
	end
	return Record
end

function Book.New(): Book
	local Fresh: Data = {
		Format = FORMAT,
		Level = 0,
		Floor = 0,
		Writes = 0,
		Cuts = 0,
		Horizon = 0,
		CutHorizon = 0,
		Writers = {},
		Timed = {},
		Cut = {},
		Untimed = {},
		Work = {},
	}
	return setmetatable(Fresh, Book)
end

function Book.Decode(Source: string): Book?
	local Ok, Record = pcall(Take, Source)
	return if Ok then Record else nil
end

function Book.Version(Source: string): number?
	local Ok, Format = pcall(Reader.Fixed, Reader.New(Source), 1)
	return if Ok then Format else nil
end

function Book.EntryWidth(Found: Entry, Now: number): number
	Writer.Clear(Scratch)
	PutEntry(Scratch, Found, Now)
	return Scratch.Cursor
end

function Book.NamedWidth(Name: string, Item: Named, Now: number): number
	Writer.Clear(Scratch)
	PutNamed(Scratch, Name, Item, Now)
	return Scratch.Cursor
end

function Book.WorkWidth(Name: string, Item: Work, Now: number): number
	Writer.Clear(Scratch)
	PutWork(Scratch, Name, Item, Now)
	return Scratch.Cursor
end

function Book.Drawn(Server: number, Counter: number): string
	local Text = Writer.New()
	Writer.Var(Text, Server)
	Writer.Var(Text, Counter)
	return `{DRAWN}{Writer.Finish(Text)}`
end

function Book.Held(self: Book, Name: string): Named?
	return self.Timed[Name] or self.Untimed[Name] or self.Cut[Name]
end

function Book.Encode(self: Book, Now: number): string
	local Text = Writer.New()
	Writer.Fixed(Text, self.Format, 1)
	Writer.Fixed(Text, if self.Id then 1 else 0, 1)
	Writer.Var(Text, self.Level)
	Writer.Var(Text, self.Floor)
	Writer.Var(Text, self.Writes)
	Writer.Var(Text, self.Cuts)
	if self.Id then
		Writer.Name(Text, self.Id)
	end
	Writer.Var(Text, Now)
	Writer.Var(Text, self.Horizon)
	Writer.Var(Text, self.CutHorizon)

	local At = Writer.Fixed(Text, 0, COUNT_WIDTH)
	local Count = 0
	for _, Found in self.Writers do
		PutEntry(Text, Found, Now)
		Count += 1
	end
	Writer.Patch(Text, At, Count, COUNT_WIDTH)

	PutRoom(Text, self.Timed, Now)
	PutRoom(Text, self.Cut, Now)
	PutRoom(Text, self.Untimed, Now)
	PutWorkRoom(Text, self.Work, Now)
	return Writer.Finish(Text)
end

Book.Fate = Fate
Book.Role = Role
Book.FORMAT = FORMAT
Book.DRAWN = DRAWN

return Book
