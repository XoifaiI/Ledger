--!strict
--!optimize 2

--[=[

	Copies: Logic. The items a followed key's copy is kept in, and how a follower reads them.

	Spec: extras 4 and 5.1 to 5.3. Model: Copy.tla and CopyAbs.tla.

	A copy item is a table like a key's value. Its s holds state, and its b holds the bookkeeping as
	alphabet text. The header's book holds the format, the write count, and the level and floor of
	the state. It also holds the parts count and the holder fields of extras 4. The header holds the
	state itself when the whole item fits Limits.ITEM_ROOM. Else Content cuts the state by its top
	level fields into at most Limits.PARTS_MAX parts. A state that needs more parts, or that has one
	field past the room, is big. The book of a part holds the write count it was cut from. Part j
	lives in the slot of the write count's parity. A push of the next write count writes the other
	slot.

	Merge is the header's transform. It keeps the larger write count. On an equal or smaller one,
	it keeps what the item holds and renews only the holder fields. It cancels while another
	holder's lease is ahead, and on an item of a newer format. Read decodes a header, or gives Behind
	for a newer format. Join puts the parts together only when every part carries the header's write
	count. Show gives a copied state as a build reads it. It is Behind past the build's floor, and
	Refused when a migration fails. Lapsed says whether the holder's lease is past. New makes what one
	server holds for one copied key.

	Return type: A table with Header, Part, Map, Content, Merge, Read, Join, Show, Lapsed, New, FORMAT
	and BIG. The types are Fresh, Header and Held.
	Example usage:
		local State = Copies.Join(Header, Values)
--]=]

local Answer = require("../Core/Answer")
local Book = require("./Book")
local Hash = require("../Encode/Hash")
local Limits = require("../Core/Constants/Limits")
local Migrate = require("./Migrate")
local Reader = require("../Encode/Reader")
local Types = require("./Types")
local Value = require("../Encode/Value")
local Windows = require("../Core/Constants/Windows")
local Writer = require("../Encode/Writer")

type State = { [string]: any }

export type Fresh = {
	read Writes: number,
	read Level: number,
	read Floor: number,
	read Parts: number,
	read State: State?,
}

export type Header = {
	read Writes: number,
	read Level: number,
	read Floor: number,
	read Parts: number,
	read State: State?,
	read Holder: number,
	read Until: number,
	read At: number,
}

export type Held = {
	read Ref: Book.Ref,
	read Mark: string,
	read Header: string,
	read Map: string,
	Writes: number,
	State: State?,
	At: number?,
	Misses: number,
	Stands: number,
	Read: number?,
	Holder: boolean,
	Running: boolean,
	Sent: number,
	Pushed: number?,
	Until: number?,
}

local FORMAT = 1
local BIG = Limits.PARTS_MAX + 1

local Copies = { FORMAT = FORMAT, BIG = BIG }

function Copies.Header(Ref: Book.Ref): string
	return `c/{Ref.Store}/{Ref.Key}`
end

function Copies.Part(Ref: Book.Ref, Writes: number, Index: number): string
	return `c/{Ref.Store}/{Ref.Key}/{Writes % 2}/{Index}`
end

function Copies.Map(Ref: Book.Ref): string
	return `Ledger_Copy_{Hash(Copies.Header(Ref)) % Limits.MAPS}`
end

local function Encode(Base: Fresh, Holder: number, Until: number, At: number): unknown
	local Text = Writer.New()
	for _, Number in { FORMAT, Base.Writes, Base.Level, Base.Floor, Base.Parts, Holder, Until, At } do
		Writer.Var(Text, Number)
	end
	return { s = Base.State, b = Writer.Finish(Text) }
end

local function Decode(Item: any): Header | "Behind"
	local Text = Reader.New(Item.b)
	if Reader.Var(Text) > FORMAT then
		return "Behind"
	end
	local Writes, Level, Floor, Parts = Reader.Var(Text), Reader.Var(Text), Reader.Var(Text), Reader.Var(Text)
	local Holder, Until, At = Reader.Var(Text), Reader.Var(Text), Reader.Var(Text)
	local State = if Parts == 0 then Item.s else nil
	if not Reader.Done(Text) or Parts > BIG or (Parts == 0 and type(State) ~= "table") then
		error("Copies: a broken header")
	end
	return { Writes = Writes, Level = Level, Floor = Floor, Parts = Parts, State = State, Holder = Holder, Until = Until, At = At }
end

function Copies.Read(Current: unknown): Header | "Behind" | nil
	local Item = if type(Current) == "table" then Current :: any else nil
	if Item == nil or type(Item.b) ~= "string" then
		return nil
	end
	local Ok, Found = pcall(Decode, Item)
	return if Ok then Found else nil
end

local function Width(Name: string, Field: unknown): number?
	local Bytes = Value.Check({ [Name] = Field })
	return if Bytes and Bytes + Limits.HEADER <= Limits.ITEM_ROOM then Bytes else nil
end

local function Cut(State: State): { State }?
	local Names: { string } = {}
	for Name in State do
		if type(Name) ~= "string" then
			return nil
		end
		table.insert(Names, Name)
	end
	table.sort(Names)
	local Cuts: { State } = {}
	local Current: State, Used = {}, 0
	for _, Name in Names do
		local Bytes = Width(Name, State[Name])
		if Bytes == nil then
			return nil
		elseif Used > 0 and Used + Bytes + Limits.HEADER > Limits.ITEM_ROOM then
			table.insert(Cuts, Current)
			Current, Used = {}, 0
		end
		Current[Name], Used = State[Name], Used + Bytes
	end
	table.insert(Cuts, Current)
	return if #Cuts <= Limits.PARTS_MAX then Cuts else nil
end

function Copies.Content(Writes: number, Level: number, Floor: number, State: State): (Fresh, { unknown })
	local Bytes = Value.Check(State)
	if Bytes and Bytes + Limits.HEADER <= Limits.ITEM_ROOM then
		return { Writes = Writes, Level = Level, Floor = Floor, Parts = 0, State = State }, {}
	end
	local Cuts = Cut(State)
	if Cuts == nil then
		return { Writes = Writes, Level = Level, Floor = Floor, Parts = BIG }, {}
	end
	local Text = Writer.New()
	Writer.Var(Text, Writes)
	local Mark = Writer.Finish(Text)
	local Pieces: { unknown } = {}
	for Index, Fields in Cuts do
		Pieces[Index] = { s = Fields, b = Mark }
	end
	return { Writes = Writes, Level = Level, Floor = Floor, Parts = #Cuts }, Pieces
end

function Copies.Merge(Current: unknown, Fresh: Fresh?, Server: number, Now: number, Until: number): unknown
	local Held = Copies.Read(Current)
	if Held == "Behind" or (Held and Held.Holder ~= Server and Held.Until > Now) then
		return nil
	end
	local Base: Fresh? = Held
	if Fresh and (Base == nil or Fresh.Writes > Base.Writes) then
		Base = Fresh
	end
	if Base == nil then
		return nil
	end
	return Encode(Base, Server, Until, Now)
end

local function Counted(Book: string): number
	local Text = Reader.New(Book)
	local Writes = Reader.Var(Text)
	return if Reader.Done(Text) then Writes else -1
end

local function Piece(Item: unknown, Writes: number): State?
	local Found = if type(Item) == "table" then Item :: any else nil
	if Found == nil or type(Found.b) ~= "string" or type(Found.s) ~= "table" then
		return nil
	end
	local Ok, Count = pcall(Counted, Found.b)
	return if Ok and Count == Writes then Found.s :: any else nil
end

function Copies.Join(Header: Header, Items: { unknown }): State?
	local State: State = {}
	for Index = 1, Header.Parts do
		local Fields = Piece(Items[Index], Header.Writes)
		if Fields == nil then
			return nil
		end
		for Name, Field in Fields do
			State[Name] = Field
		end
	end
	return State
end

function Copies.Show(Header: Header, State: State, Build: Types.Build): State | Answer.Answer
	if Header.Floor > Build.Floor then
		return Answer.Behind
	elseif Header.Level < Build.Level then
		local Migrated = Migrate(State, Header.Level, Build)
		return if Migrated == nil then Answer.Refused else Migrated :: State
	end
	return State
end

function Copies.Lapsed(Header: Header, Now: number, Slack: number): boolean
	return Now > Header.Until + Slack
end

function Copies.New(Ref: Book.Ref): Held
	return {
		Ref = Ref,
		Mark = `{Ref.Store}/{Ref.Key}`,
		Header = Copies.Header(Ref),
		Map = Copies.Map(Ref),
		Writes = 0,
		Misses = 0,
		Stands = 0,
		Holder = false,
		Running = false,
		Sent = 0,
	}
end

return Copies
