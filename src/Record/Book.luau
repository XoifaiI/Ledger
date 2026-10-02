--!strict
--!optimize 2

--[=[
	Book: Logic. The record's bookkeeping, as an object and as the text in a key's b field.

	Spec: record 2.2 and 2.3; transaction 2; cuts 2 and 3.4.

	The text holds the fixed fields, then each room as a count and its items. Room stamps are stored
	as offsets from the clock of the write. A drawn name is held behind DRAWN and stored as its
	server number and counter. A named entry has a role: an op's name, a leg's fate or a decision.
	The work room holds escrow marks, exclusive marks and pinned records by name, and WorkForm names
	the three. The gate holds the one cut in progress. The loss room holds events and at most
	SLOTS_MAX fold slots. A slot is an exact sum per money field, kept as two limbs of Alphabet.LIMB.
	A seal is what an erase leaves in place of the value. Decode and DecodeSeal give nil for any text
	the encoders do not write. LossFloor is the least loss room for a count of money fields:
	SLOTS_MAX of the widest slots and one of the widest reset events, measured with these encoders.
	Every fate, role, cause and head bit here is stored, so none may change.

	Return type: The Book class, and the types of its items.
	Example usage:
		local Again = Book.Decode(Record:Encode(Now))
--]=]

local Alphabet = require("../Encode/Alphabet")
local Limits = require("../Core/Constants/Limits")
local Reader = require("../Encode/Reader")
local Windows = require("../Core/Constants/Windows")
local Writer = require("../Encode/Writer")

local WorkForm = {
	Escrow = "Escrow" :: "Escrow",
	Exclusive = "Exclusive" :: "Exclusive",
	Pinned = "Pinned" :: "Pinned",
}

export type WorkForm = keyof<typeof(WorkForm)>

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
	read Slot: { string }?,
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
	LossWidth: (Events: { Event }, Slots: { Slot }, Now: number) -> number,
	EncodeSeal: (Item: Seal) -> string,
	DecodeSeal: (Source: string) -> Seal?,
	LegFate: (Stamp: number, Print: number?, Code: Fate, Attempt: number) -> Named,
	Decision: (Stamp: number, Print: number?, Code: Fate, Attempt: number, Final: boolean?, Value: number?) -> Named,
	Marks: (Room: { [string]: Work }) -> { [string]: Work },
	Of: (Room: { [string]: Work }, Form: WorkForm) -> { [string]: Work },
	AsMark: (Item: Work) -> (Escrow | Exclusive)?,
	AsPinned: (Item: Work) -> Pinned?,
	Address: (Held: Ref) -> string,
	WorkForm: typeof(WorkForm),
	Fate: { read Took: number, read Refused: number, read Full: number, read Fenced: number, read Aborted: number, read Turned: number },
	Role: { read Op: number, read Leg: number, read Decision: number },
	Cause: { read Reset: number, read Erase: number, read Returned: number, read Orphan: number },
	FORMAT: number,
	DRAWN: string,
	SLOTS_MAX: number,
	Held: (self: Book, Name: string) -> Named?,
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
local SLOT_COUNT_WIDTH = 1
local ROLES = 3
local SLOTS_MAX = 2
local OFF_ALPHABET = "!"

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

local FLAGS = {
	Id = 1,
	Gate = 2,
}

local NAMED_HEAD = {
	FateSpan = 8,
	FencedFinal = 6,
	Base64 = 8,
	Game = 16,
	Value = 32,
}

local WORK_HEAD = {
	FormSpan = 4,
	Escrow = 0,
	Exclusive = 1,
	Pinned = 2,
	Clean = 4,
	Base64 = 8,
	Game = 16,
	Payload = 32,
}

local GATE_HEAD = {
	Base64 = 8,
	Game = 16,
}

local EVENT_HEAD = {
	CauseSpan = 4,
	Base64 = 4,
	Game = 8,
	Ref = 16,
}

local Book = {} :: BookImpl
Book.__index = Book
Book.WorkForm = WorkForm
Book.Fate = Fate
Book.Role = Role
Book.Cause = Cause
Book.FORMAT = FORMAT
Book.DRAWN = DRAWN
Book.SLOTS_MAX = SLOTS_MAX

local function IsDrawn(Name: string): boolean
	return string.sub(Name, 1, #DRAWN) == DRAWN
end

local function CheckFingerprint(Noun: string, Name: string, Print: number?)
	if (Print ~= nil) == IsDrawn(Name) then
		error(`Book: the {Noun} {Name} and its fingerprint disagree about who chose it`, 0)
	end
end

local function StoresAttempt(ItemRole: number, Code: Fate): boolean
	return ItemRole ~= Role.Op or Code == Fate.Fenced or Code == Fate.Aborted
end

local function PutLabel(Text: Writer.Writer, Name: string): (boolean, boolean)
	local Game = not IsDrawn(Name)
	local Stored = if Game then Name else string.sub(Name, #DRAWN + 1)
	return Writer.Label(Text, Stored), Game
end

local function PutNamed(Text: Writer.Writer, Name: string, Item: Named, Now: number)
	CheckFingerprint("name", Name, Item.Print)
	if Item.Final and Item.Fate ~= Fate.Fenced then
		error(`Book: only a fence is final, and {Name} is not fenced`, 0)
	end
	local ItemRole = Item.Role or Role.Op
	local At = Writer.Fixed(Text, 0, 1)
	Writer.Var(Text, Item.Kind * ROLES + ItemRole)
	local Base64, Game = PutLabel(Text, Name)
	local Head = if Item.Final then NAMED_HEAD.FencedFinal else Item.Fate
	if Base64 then
		Head += NAMED_HEAD.Base64
	end
	if Game then
		Head += NAMED_HEAD.Game
	end
	if Item.Value then
		Head += NAMED_HEAD.Value
	end
	Writer.Patch(Text, At, Head, 1)
	Writer.Signed(Text, Item.Stamp - Now)
	if StoresAttempt(ItemRole, Item.Fate) then
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

local function PutWriters(Text: Writer.Writer, Writers: { [number]: Entry }, Now: number)
	local At = Writer.Fixed(Text, 0, COUNT_WIDTH)
	local Count = 0
	for _, Found in Writers do
		PutEntry(Text, Found, Now)
		Count += 1
	end
	Writer.Patch(Text, At, Count, COUNT_WIDTH)
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
	CheckFingerprint("name", Name, Item.Print)
	if Item.Attempt < 1 then
		error(`Book: {Name} has no attempt`, 0)
	end
	local At = Writer.Fixed(Text, 0, 1)
	local Base64, Game = PutLabel(Text, Name)
	Writer.Signed(Text, Item.Stamp - Now)
	Writer.Var(Text, Item.Attempt)
	if Item.Print then
		Writer.Fixed(Text, Item.Print, PRINT_WIDTH)
	end
	local Head = 0
	if Base64 then
		Head += WORK_HEAD.Base64
	end
	if Game then
		Head += WORK_HEAD.Game
	end
	if Item.Form == WorkForm.Pinned then
		Head += WORK_HEAD.Pinned
		Writer.Var(Text, #Item.Legs)
		for _, Leg in Item.Legs do
			PutRef(Text, Leg)
		end
		if Item.Value then
			Head += WORK_HEAD.Payload
			Writer.Var(Text, Item.Value)
		end
	else
		Head += if Item.Form == WorkForm.Escrow then WORK_HEAD.Escrow else WORK_HEAD.Exclusive
		if Item.Clean then
			Head += WORK_HEAD.Clean
		end
		PutRef(Text, Item.Decider)
		if Item.Form == WorkForm.Escrow then
			Writer.Var(Text, Item.Field)
			Writer.Signed(Text, Item.Amount)
		elseif Item.Slot then
			Head += WORK_HEAD.Payload
			Writer.Var(Text, #Item.Slot)
			for _, Step in Item.Slot do
				Writer.Name(Text, Step)
			end
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

local function PutGate(Text: Writer.Writer, Item: Gate, Now: number)
	CheckFingerprint("gate", Item.Name, Item.Print)
	local At = Writer.Fixed(Text, 0, 1)
	local Base64, Game = PutLabel(Text, Item.Name)
	Writer.Var(Text, Item.Kind)
	Writer.Signed(Text, Item.Stamp - Now)
	Writer.Signed(Text, Item.At - Now)
	if Item.Print then
		Writer.Fixed(Text, Item.Print, PRINT_WIDTH)
	end
	local Head = 0
	if Base64 then
		Head += GATE_HEAD.Base64
	end
	if Game then
		Head += GATE_HEAD.Game
	end
	Writer.Patch(Text, At, Head, 1)
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
	local Head = Item.Cause
	if Base64 then
		Head += EVENT_HEAD.Base64
	end
	if Game then
		Head += EVENT_HEAD.Game
	end
	if Item.Ref then
		Head += EVENT_HEAD.Ref
	end
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
	Writer.Fixed(Text, #Slots, SLOT_COUNT_WIDTH)
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

local function TakeLabel(Text: Reader.Reader, Base64: boolean, Game: boolean): string
	local Name = Reader.Label(Text, Base64)
	return if Game then Name else `{DRAWN}{Name}`
end

local function TakeRoom(Text: Reader.Reader, Now: number): { [string]: Named }
	local Room: { [string]: Named } = {}
	for _ = 1, Reader.Fixed(Text, COUNT_WIDTH) do
		local Head = Reader.Fixed(Text, 1)
		local Final = Head % NAMED_HEAD.FateSpan == NAMED_HEAD.FencedFinal
		local Code = if Final then Fate.Fenced else TakeFate(Head % NAMED_HEAD.FateSpan)
		local Kind = Reader.Var(Text)
		local ItemRole = Kind % ROLES
		local Game = bit32.btest(Head, NAMED_HEAD.Game)
		local Name = TakeLabel(Text, bit32.btest(Head, NAMED_HEAD.Base64), Game)
		local Item: Named = { Kind = Kind // ROLES, Stamp = Now + Reader.Signed(Text), Fate = Code }
		if ItemRole ~= Role.Op then
			Item.Role = ItemRole
		end
		if StoresAttempt(ItemRole, Code) then
			Item.Attempt = Reader.Var(Text)
		end
		if Final then
			Item.Final = true
		end
		if Game then
			Item.Print = Reader.Fixed(Text, PRINT_WIDTH)
		end
		if bit32.btest(Head, NAMED_HEAD.Value) then
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
		local Form = Head % WORK_HEAD.FormSpan
		local Game = bit32.btest(Head, WORK_HEAD.Game)
		local Name = TakeLabel(Text, bit32.btest(Head, WORK_HEAD.Base64), Game)
		local Stamp = Now + Reader.Signed(Text)
		local Attempt = Reader.Var(Text)
		local Print = if Game then Reader.Fixed(Text, PRINT_WIDTH) else nil
		if Attempt < 1 or Room[Name] then
			error("Book: a work item with no attempt, or one name twice", 0)
		end
		local Clean = bit32.btest(Head, WORK_HEAD.Clean)
		local HasPayload = bit32.btest(Head, WORK_HEAD.Payload)
		if Form == WORK_HEAD.Pinned and not Clean then
			local Legs: { Ref } = {}
			for Index = 1, Reader.Var(Text) do
				Legs[Index] = TakeRef(Text)
			end
			local Value = if HasPayload then Reader.Var(Text) else nil
			Room[Name] = { Form = WorkForm.Pinned, Stamp = Stamp, Attempt = Attempt, Print = Print, Legs = Legs, Value = Value }
		elseif Form == WORK_HEAD.Escrow and not HasPayload then
			local Decider = TakeRef(Text)
			local Field = Reader.Var(Text)
			Room[Name] = {
				Form = WorkForm.Escrow,
				Stamp = Stamp,
				Attempt = Attempt,
				Print = Print,
				Clean = Clean,
				Decider = Decider,
				Field = Field,
				Amount = Reader.Signed(Text),
			}
		elseif Form == WORK_HEAD.Exclusive then
			local Decider = TakeRef(Text)
			local Slot: { string }? = nil
			if HasPayload then
				local Steps: { string } = {}
				for Index = 1, Reader.Var(Text) do
					Steps[Index] = Reader.Name(Text)
				end
				Slot = Steps
			end
			Room[Name] = { Form = WorkForm.Exclusive, Stamp = Stamp, Attempt = Attempt, Print = Print, Clean = Clean, Decider = Decider, Slot = Slot }
		else
			error(`Book: {Head} is not the head of a work item`, 0)
		end
	end
	return Room
end

local function TakeWriters(Text: Reader.Reader, Now: number): { [number]: Entry }
	local Writers: { [number]: Entry } = {}
	for _ = 1, Reader.Fixed(Text, COUNT_WIDTH) do
		local Id = Reader.Var(Text)
		local Lo = Reader.Var(Text)
		local Stamp = Now + Reader.Signed(Text)
		local Fates: { [number]: Fate } = {}
		for _ = 1, Reader.Var(Text) do
			local Seq = Lo - Reader.Var(Text)
			Fates[Seq] = TakeFate(Reader.Fixed(Text, 1))
		end
		if Writers[Id] then
			error("Book: two entries for one writer", 0)
		end
		Writers[Id] = { Id = Id, Lo = Lo, Stamp = Stamp, Fates = Fates }
	end
	return Writers
end

local function TakeGate(Text: Reader.Reader, Now: number): Gate
	local Head = Reader.Fixed(Text, 1)
	if bit32.band(Head, GATE_HEAD.Base64 + GATE_HEAD.Game) ~= Head then
		error(`Book: {Head} is not the head of a gate`, 0)
	end
	local Game = bit32.btest(Head, GATE_HEAD.Game)
	local Name = TakeLabel(Text, bit32.btest(Head, GATE_HEAD.Base64), Game)
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
		if Head >= EVENT_HEAD.Ref * 2 then
			error(`Book: {Head} is not the head of an event`, 0)
		end
		local Name = TakeLabel(Text, bit32.btest(Head, EVENT_HEAD.Base64), bit32.btest(Head, EVENT_HEAD.Game))
		local Stamp = Now + Reader.Signed(Text)
		local Amounts = TakeFields(Text, Reader.Signed)
		local Ref = if bit32.btest(Head, EVENT_HEAD.Ref) then TakeRef(Text) else nil
		table.insert(Events, { Cause = Head % EVENT_HEAD.CauseSpan, Name = Name, Stamp = Stamp, Amounts = Amounts, Ref = Ref })
	end
	local Slots: { Slot } = {}
	local Count = Reader.Fixed(Text, SLOT_COUNT_WIDTH)
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
	if Flags > FLAGS.Id + FLAGS.Gate then
		error(`Book: flags {Flags} are not ones this build writes`, 0)
	end
	Record.Level = Reader.Var(Text)
	Record.Floor = Reader.Var(Text)
	Record.Writes = Reader.Var(Text)
	Record.Cuts = Reader.Var(Text)
	if bit32.btest(Flags, FLAGS.Id) then
		Record.Id = Reader.Name(Text)
	end
	local Now = Reader.Var(Text)
	Record.Horizon = Reader.Var(Text)
	Record.CutHorizon = Reader.Var(Text)
	if bit32.btest(Flags, FLAGS.Gate) then
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

function Book.LossWidth(Events: { Event }, Slots: { Slot }, Now: number): number
	local Total = COUNT_WIDTH + SLOT_COUNT_WIDTH
	for _, Item in Events do
		Total += Book.EventWidth(Item, Now)
	end
	for _, Item in Slots do
		Total += Book.SlotWidth(Item)
	end
	return Total
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

function Book.LegFate(Stamp: number, Print: number?, Code: Fate, Attempt: number): Named
	return { Kind = 0, Role = Role.Leg, Stamp = Stamp, Fate = Code, Attempt = Attempt, Print = Print }
end

function Book.Decision(Stamp: number, Print: number?, Code: Fate, Attempt: number, Final: boolean?, Value: number?): Named
	return { Kind = 0, Role = Role.Decision, Stamp = Stamp, Fate = Code, Attempt = Attempt, Print = Print, Final = if Final then true else nil, Value = Value }
end

function Book.Marks(Room: { [string]: Work }): { [string]: Work }
	local Found: { [string]: Work } = {}
	for Name, Item in Room do
		if Item.Form ~= WorkForm.Pinned then
			Found[Name] = Item
		end
	end
	return Found
end

function Book.Of(Room: { [string]: Work }, Form: WorkForm): { [string]: Work }
	local Found: { [string]: Work } = {}
	for Name, Item in Room do
		if Item.Form == Form then
			Found[Name] = Item
		end
	end
	return Found
end

function Book.AsMark(Item: Work): (Escrow | Exclusive)?
	if Item.Form == WorkForm.Pinned then
		return nil
	end
	return Item
end

function Book.AsPinned(Item: Work): Pinned?
	if Item.Form == WorkForm.Pinned then
		return Item
	end
	return nil
end

function Book.Address(Held: Ref): string
	return `{Held.Store}/{Held.Key}`
end

function Book.Held(self: Book, Name: string): Named?
	return self.Timed[Name] or self.Untimed[Name] or self.Cut[Name]
end

function Book.Encode(self: Book, Now: number): string
	local Text = Writer.New()
	local Flags = 0
	if self.Id then
		Flags += FLAGS.Id
	end
	if self.Gate then
		Flags += FLAGS.Gate
	end
	Writer.Fixed(Text, self.Format, 1)
	Writer.Fixed(Text, Flags, 1)
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
	PutWriters(Text, self.Writers, Now)
	PutRoom(Text, self.Timed, Now)
	PutRoom(Text, self.Cut, Now)
	PutRoom(Text, self.Untimed, Now)
	PutWorkRoom(Text, self.Work, Now)
	PutLosses(Text, self.Events, self.Slots, Now)
	return Writer.Finish(Text)
end

return Book
