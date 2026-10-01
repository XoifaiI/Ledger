--!strict
--!optimize 2

--[=[

	Book: Logic. The record's bookkeeping, as an object and as the text in a key's b field.

	Spec: record 2.2 and 2.3; transaction 2; cuts 2 and 3.4.

	The text holds the fixed fields, then each room as a count and its items. Room stamps are stored
	as offsets from the clock of the write. A drawn name is held behind DRAWN and stored as its
	server number and counter. A named entry has a role: an op's name, a leg's fate or a decision,
	stored with its kind. The work room holds escrow marks, exclusive marks and pinned records by
	name. The gate holds the one cut in progress. The loss room holds events and at most two fold
	slots. An event is a reset that destroyed money, or a named return of the orphan rule. A slot is
	an exact sum per money field, kept as two limbs of Alphabet.LIMB. A seal is what an erase leaves
	in place of the value: its cut, the server that sealed, rt, and the namings. Decode and
	DecodeSeal refuse any text the encoders do not write, and give back nil for it. Version reads
	only the format. The Width functions give the width of one item. LossFloor gives the least loss
	room for a count of money fields. It holds two of the widest fold slots and one of the widest
	reset events, as these encoders write them. Incarnation gives the id a key is made with.

	Return type: The Book class, with New, Decode, Drawn, Incarnation, Version, EntryWidth, NamedWidth,
	WorkWidth, EventWidth, SlotWidth, LossFloor, EncodeSeal, DecodeSeal, Fate, Role, Cause, FORMAT and DRAWN, and
	the methods Held and Encode. The types are Entry, Named, Ref, Escrow, Exclusive, Pinned, Work,
	Gate, Event, Sum, Slot and Seal.
	Example usage:
		local Again = Book.Decode(Record:Encode(Now))
--]=]

local Alphabet = require("../Encode/Alphabet")
local Limits = require("../Core/Constants/Limits")
local Reader = require("../Encode/Reader")
local Windows = require("../Core/Constants/Windows")
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

export type Gate = {
	read Name: string,
	read Stamp: number,
	read Kind: number,
	read Print: number?,
	read At: number,
}

export type Event = {
	read Cause: number,
	read Name: string,
	read Stamp: number,
	read Amounts: { [number]: number },
	read Ref: Ref?,
}

export type Sum = {
	High: number,
	Low: number,
}

export type Slot = {
	read Period: number,
	Count: number,
	read Sums: { [number]: Sum },
}

export type Seal = {
	read Name: string,
	read Stamp: number,
	read Print: number?,
	read Server: number,
	read Rt: number,
	read Events: { Event },
	read Slots: { Slot },
}

type BookImpl = {
	__index: BookImpl,
	Held: (self: Book, Name: string) -> Named?,
	New: () -> Book,
	Decode: (Source: string) -> Book?,
	Version: (Source: string) -> number?,
	Drawn: (Server: number, Counter: number) -> string,
	Incarnation: (Server: number, Counter: number) -> string,
	EntryWidth: (Found: Entry, Now: number) -> number,
	NamedWidth: (Name: string, Item: Named, Now: number) -> number,
	WorkWidth: (Name: string, Item: Work, Now: number) -> number,
	EventWidth: (Item: Event, Now: number) -> number,
	SlotWidth: (Item: Slot) -> number,
	LossFloor: (Fields: number) -> number,
	EncodeSeal: (Item: Seal) -> string,
	DecodeSeal: (Source: string) -> Seal?,
	Fate: { read Took: number, read Refused: number, read Full: number, read Fenced: number, read Aborted: number, read Turned: number },
	Role: { read Op: number, read Leg: number, read Decision: number },
	Cause: { read Reset: number, read Erase: number, read Returned: number, read Orphan: number },
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
	Gate: Gate?,
	Writers: { [number]: Entry },
	Timed: { [string]: Named },
	Cut: { [string]: Named },
	Untimed: { [string]: Named },
	Work: { [string]: Work },
	Events: { Event },
	Slots: { Slot },
}

export type Book = setmetatable<Data, BookImpl>

local FORMAT = 1
local DRAWN = "\255"
local COUNT_WIDTH = 3
local PRINT_WIDTH = 3

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

local Cause = {
	Reset = 0,
	Erase = 1,
	Returned = 2,
	Orphan = 3,
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
local HAS_ID = 1
local HAS_GATE = 2
local CAUSES = 4
local EVENT_BASE64 = 4
local EVENT_GAME = 8
local EVENT_REF = 16
local SLOTS_MAX = 2
local OFF_ALPHABET = "!"

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
	local Base64 = Writer.Label(Text, if Game then Name else string.sub(Name, #DRAWN + 1))
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
		Writer.Fixed(Text, Item.Print, PRINT_WIDTH)
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
	local Base64 = Writer.Label(Text, if Game then Name else string.sub(Name, #DRAWN + 1))
	Writer.Signed(Text, Item.Stamp - Now)
	Writer.Var(Text, Item.Attempt)
	if Item.Print then
		Writer.Fixed(Text, Item.Print, PRINT_WIDTH)
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

local function PutLabel(Text: Writer.Writer, Name: string): (boolean, boolean)
	local Game = string.sub(Name, 1, 1) ~= DRAWN
	return Writer.Label(Text, if Game then Name else string.sub(Name, #DRAWN + 1)), Game
end

local function PutGate(Text: Writer.Writer, Item: Gate, Now: number)
	local At = Writer.Fixed(Text, 0, 1)
	local Base64, Game = PutLabel(Text, Item.Name)
	if Game ~= (Item.Print ~= nil) then
		error(`Book: the gate {Item.Name} and its fingerprint disagree about who chose it`, 0)
	end
	Writer.Var(Text, Item.Kind)
	Writer.Signed(Text, Item.Stamp - Now)
	Writer.Signed(Text, Item.At - Now)
	if Item.Print then
		Writer.Fixed(Text, Item.Print, PRINT_WIDTH)
	end
	Writer.Patch(Text, At, (if Base64 then BASE64 else 0) + (if Game then GAME else 0), 1)
end

local function Magnitude(Item: Sum): (boolean, number, number)
	if Item.High >= 0 then
		return false, Item.High, Item.Low
	elseif Item.Low == 0 then
		return true, -Item.High, 0
	end
	return true, -Item.High - 1, Alphabet.LIMB - Item.Low
end

local function Limbs(Negative: boolean, High: number, Low: number): Sum
	if not Negative then
		return { High = High, Low = Low }
	elseif Low == 0 then
		return { High = -High, Low = 0 }
	end
	return { High = -High - 1, Low = Alphabet.LIMB - Low }
end

local function Sorted(Fields: { [number]: any }): { number }
	local Order: { number } = {}
	for Field in Fields do
		table.insert(Order, Field)
	end
	table.sort(Order)
	return Order
end

local function PutEvent(Text: Writer.Writer, Item: Event, Now: number)
	local At = Writer.Fixed(Text, 0, 1)
	local Base64, Game = PutLabel(Text, Item.Name)
	Writer.Signed(Text, Item.Stamp - Now)
	local Fields = Sorted(Item.Amounts)
	Writer.Var(Text, #Fields)
	for _, Field in Fields do
		Writer.Var(Text, Field)
		Writer.Signed(Text, Item.Amounts[Field])
	end
	if Item.Ref then
		PutRef(Text, Item.Ref)
	end
	local Head = Item.Cause + (if Base64 then EVENT_BASE64 else 0) + (if Game then EVENT_GAME else 0) + (if Item.Ref then EVENT_REF else 0)
	Writer.Patch(Text, At, Head, 1)
end

local function PutSlot(Text: Writer.Writer, Item: Slot)
	Writer.Var(Text, Item.Period)
	Writer.Var(Text, Item.Count)
	local Fields = Sorted(Item.Sums)
	Writer.Var(Text, #Fields)
	for _, Field in Fields do
		Writer.Var(Text, Field)
		Writer.Wide(Text, Magnitude(Item.Sums[Field]))
	end
end

local function PutLosses(Text: Writer.Writer, Events: { Event }, Slots: { Slot }, Now: number)
	if #Slots > SLOTS_MAX then
		error("Book: more fold slots than a loss room keeps", 0)
	end
	Writer.Fixed(Text, #Events, COUNT_WIDTH)
	for _, Item in Events do
		PutEvent(Text, Item, Now)
	end
	Writer.Fixed(Text, #Slots, 1)
	for _, Item in Slots do
		PutSlot(Text, Item)
	end
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
			Item.Print = Reader.Fixed(Text, PRINT_WIDTH)
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
		local Print = if bit32.btest(Head, GAME) then Reader.Fixed(Text, PRINT_WIDTH) else nil
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

local function TakeLabel(Text: Reader.Reader, Base64: boolean, Game: boolean): string
	local Name = Reader.Label(Text, Base64)
	return if Game then Name else `{DRAWN}{Name}`
end

local function TakeGate(Text: Reader.Reader, Now: number): Gate
	local Head = Reader.Fixed(Text, 1)
	if bit32.band(Head, BASE64 + GAME) ~= Head then
		error(`Book: {Head} is not the head of a gate`, 0)
	end
	local Game = bit32.btest(Head, GAME)
	local Name = TakeLabel(Text, bit32.btest(Head, BASE64), Game)
	local Kind = Reader.Var(Text)
	local Stamp = Now + Reader.Signed(Text)
	local At = Now + Reader.Signed(Text)
	local Print = if Game then Reader.Fixed(Text, PRINT_WIDTH) else nil
	if Kind ~= Cause.Reset and Kind ~= Cause.Erase then
		error(`Book: {Kind} is not the kind of a cut`, 0)
	end
	return { Name = Name, Kind = Kind, Stamp = Stamp, At = At, Print = Print }
end

local function TakeFields(Text: Reader.Reader, Take: (Text: Reader.Reader) -> any): { [number]: any }
	local Fields: { [number]: any } = {}
	local Last = 0
	for _ = 1, Reader.Var(Text) do
		local Field = Reader.Var(Text)
		if Field <= Last then
			error("Book: fields out of order", 0)
		end
		Last = Field
		Fields[Field] = Take(Text)
	end
	return Fields
end

local function TakeSum(Text: Reader.Reader): Sum
	return Limbs(Reader.Wide(Text))
end

local function TakeLosses(Text: Reader.Reader, Now: number): ({ Event }, { Slot })
	local Events: { Event } = {}
	for _ = 1, Reader.Fixed(Text, COUNT_WIDTH) do
		local Head = Reader.Fixed(Text, 1)
		if Head >= EVENT_REF * 2 then
			error(`Book: {Head} is not the head of an event`, 0)
		end
		local Name = TakeLabel(Text, bit32.btest(Head, EVENT_BASE64), bit32.btest(Head, EVENT_GAME))
		local Stamp = Now + Reader.Signed(Text)
		local Amounts = TakeFields(Text, Reader.Signed)
		local Ref = if bit32.btest(Head, EVENT_REF) then TakeRef(Text) else nil
		table.insert(Events, { Cause = Head % CAUSES, Name = Name, Stamp = Stamp, Amounts = Amounts, Ref = Ref })
	end
	local Slots: { Slot } = {}
	local Count = Reader.Fixed(Text, 1)
	if Count > SLOTS_MAX then
		error("Book: more fold slots than a loss room keeps", 0)
	end
	for _ = 1, Count do
		local Period = Reader.Var(Text)
		local Folded = Reader.Var(Text)
		table.insert(Slots, { Period = Period, Count = Folded, Sums = TakeFields(Text, TakeSum) })
	end
	return Events, Slots
end

local function Take(Source: string): Book
	local Text = Reader.New(Source)
	local Record = Book.New()
	Record.Format = Reader.Fixed(Text, 1)
	if Record.Format ~= FORMAT then
		error(`Book: format {Record.Format} is not one this build reads`, 0)
	end
	local Flags = Reader.Fixed(Text, 1)
	if Flags > HAS_ID + HAS_GATE then
		error(`Book: flags {Flags} are not ones this build writes`, 0)
	end
	Record.Level = Reader.Var(Text)
	Record.Floor = Reader.Var(Text)
	Record.Writes = Reader.Var(Text)
	Record.Cuts = Reader.Var(Text)
	if bit32.btest(Flags, HAS_ID) then
		Record.Id = Reader.Name(Text)
	end
	local Now = Reader.Var(Text)
	Record.Horizon = Reader.Var(Text)
	Record.CutHorizon = Reader.Var(Text)
	if bit32.btest(Flags, HAS_GATE) then
		Record.Gate = TakeGate(Text, Now)
	end
	Record.Writers = TakeWriters(Text, Now)
	Record.Timed = TakeRoom(Text, Now)
	Record.Cut = TakeRoom(Text, Now)
	Record.Untimed = TakeRoom(Text, Now)
	Record.Work = TakeWork(Text, Now)
	Record.Events, Record.Slots = TakeLosses(Text, Now)
	if not Reader.Done(Text) then
		error("Book: text past the last room", 0)
	end
	return Record
end

local function TakeSeal(Source: string): Seal
	local Text = Reader.New(Source)
	if Reader.Fixed(Text, 1) ~= FORMAT then
		error("Book: a seal of a format this build does not read", 0)
	end
	local Server = Reader.Var(Text)
	local Rt = Reader.Var(Text)
	local Cut = TakeGate(Text, Rt)
	local Events, Slots = TakeLosses(Text, Rt)
	if Cut.Kind ~= Cause.Erase or not Reader.Done(Text) then
		error("Book: a seal of no erase, or text past the seal", 0)
	end
	return { Name = Cut.Name, Stamp = Cut.Stamp, Print = Cut.Print, Server = Server, Rt = Rt, Events = Events, Slots = Slots }
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
		Events = {},
		Slots = {},
	}
	return setmetatable(Fresh, Book)
end

function Book.Decode(Source: string): Book?
	local Ok, Record = pcall(Take, Source)
	return if Ok then Record else nil
end

function Book.DecodeSeal(Source: string): Seal?
	local Ok, Found = pcall(TakeSeal, Source)
	return if Ok then Found else nil
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

function Book.EventWidth(Item: Event, Now: number): number
	Writer.Clear(Scratch)
	PutEvent(Scratch, Item, Now)
	return Scratch.Cursor
end

function Book.SlotWidth(Item: Slot): number
	Writer.Clear(Scratch)
	PutSlot(Scratch, Item)
	return Scratch.Cursor
end

function Book.LossFloor(Fields: number): number
	local Amounts: { [number]: number } = {}
	local Sums: { [number]: Sum } = {}
	for Field = Limits.MONEY_MAX - Fields + 1, Limits.MONEY_MAX do
		Amounts[Field] = -(Limits.MONEY_LIMIT - 1)
		Sums[Field] = { High = Writer.WIDE_HIGH - 1, Low = Alphabet.LIMB - 1 }
	end
	local Name = string.rep(OFF_ALPHABET, Limits.NAME_BYTES)
	local Event: Event = { Cause = Cause.Reset, Name = Name, Stamp = Limits.STAMP_MAX, Amounts = Amounts }
	local Slot: Slot = { Period = Limits.STAMP_MAX // Windows.FOLD_SPAN, Count = Limits.MONEY_LIMIT - 1, Sums = Sums }
	return SLOTS_MAX * Book.SlotWidth(Slot) + Book.EventWidth(Event, 0)
end

function Book.EncodeSeal(Item: Seal): string
	local Text = Writer.New()
	Writer.Fixed(Text, FORMAT, 1)
	Writer.Var(Text, Item.Server)
	Writer.Var(Text, Item.Rt)
	PutGate(Text, { Name = Item.Name, Stamp = Item.Stamp, Kind = Cause.Erase, Print = Item.Print, At = Item.Rt }, Item.Rt)
	PutLosses(Text, Item.Events, Item.Slots, Item.Rt)
	return Writer.Finish(Text)
end

function Book.Drawn(Server: number, Counter: number): string
	local Text = Writer.New()
	Writer.Var(Text, Server)
	Writer.Var(Text, Counter)
	return `{DRAWN}{Writer.Finish(Text)}`
end

function Book.Incarnation(Server: number, Counter: number): string
	return string.sub(Book.Drawn(Server, Counter), #DRAWN + 1)
end

function Book.Held(self: Book, Name: string): Named?
	return self.Timed[Name] or self.Untimed[Name] or self.Cut[Name]
end

function Book.Encode(self: Book, Now: number): string
	local Text = Writer.New()
	Writer.Fixed(Text, self.Format, 1)
	Writer.Fixed(Text, (if self.Id then HAS_ID else 0) + (if self.Gate then HAS_GATE else 0), 1)
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
	if self.Gate then
		PutGate(Text, self.Gate, Now)
	end

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
	PutLosses(Text, self.Events, self.Slots, Now)
	return Writer.Finish(Text)
end

Book.Fate = Fate
Book.Role = Role
Book.Cause = Cause
Book.FORMAT = FORMAT
Book.DRAWN = DRAWN

return Book
