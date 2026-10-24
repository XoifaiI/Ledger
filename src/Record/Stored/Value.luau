--!strict
--!optimize 2

--[=[
	Value: a key's value (spec/protocols/record/Format.md 5, 10) as the DataStore table: the state s and its book b, or
	a seal z, and no other keys. A build's key kind says what s is: a table, a shard's integer, a part's text. A build's
	MayReference, if any, judges each key a mark or pinned record names: a value naming one its store cannot hold is not
	Ledger's. b's windows are in the caller's WindowUnit. The reader throws through Format.Malformed; DecodeValue gives
	nil and DecodeStored the Unreadable cause, Newer or Foreign.

	Return type: A plain table of functions and the Value, Kept, Decoded, Unreadable, UnreadableCause and KeyBuild
	types.
	Example usage:
		local Kept = { Kind = "Kept", State = {}, Book = Empty }
		Value.EncodeValue(Kept, Build, Limits.WindowUnit) --> { s = {}, b = "AAAABAAA..." }
		Value.StateFits(Setup.Encoding, State, Limits.StateCap) --> true
--]=]

local Balances = require("../Legs/Balances")
local Book = require("./Book")
local Extras = require("../Constants/Extras")
local Format = require("../Encoding/Format")
local Guards = require("../Judging/Guards")
local HashInputs = require("../Encoding/HashInputs")
local Json = require("../Encoding/Json")
local Names = require("../Encoding/Names")
local Part = require("./Items/Part")
local Post = require("./Post")
local Record = require("../Constants/Record")
local Seal = require("./Items/Seal")

type Book = Book.Book
type StateForm = Book.StateForm
type Encoding = HashInputs.Encoding
type DiffEntry = Post.DiffEntry
type Arithmetic = Balances.Arithmetic
type KeyKind = Record.KeyKind
type KeyReference = Names.KeyReference

export type Kept = { Kind: "Kept", State: Fields, Book: Book, Post: { DiffEntry }?, Given: Fields? }

export type Value = Kept | { Kind: "Sealed", Seal: Seal.Seal }

export type UnreadableCause = "Newer" | "Foreign"

export type Unreadable = { read Kind: "Unreadable", read Cause: UnreadableCause }

export type Decoded = Value | Unreadable

export type Fields = { [unknown]: unknown }

export type KeyBuild = {
	read KeyKind: KeyKind,
	read Balances: { [string]: Arithmetic },
	read MayReference: ((Reference: KeyReference) -> boolean)?,
}

type Measure = {
	Bytes: number,
	Packed: string?,
}

local Malformed = Format.Malformed
local Storable = Guards.Storable

local EncodeBook = Book.EncodeBook
local ReadBookText = Book.ReadBookText

local EncodePost = Post.EncodePost
local ReadPost = Post.ReadPost

local EncodeSeal = Seal.EncodeSeal
local ReadSealText = Seal.ReadSealText

local KeyKinds = Record.KeyKind
local ShardSumField = Extras.ShardSumField
local StateForms = Book.StateForm

local StateCap = Record.StateCap
local PackedStateMost = Record.PackedStateMost
local BufferFramingBytes = Record.BufferFramingBytes
local PackedSlackBytes = Record.PackedSlackBytes
local Base64GroupBytes = 3
local Base64GroupCharacters = 4

local Measures: { [Fields]: Measure } = {}
setmetatable(Measures, { __mode = "k" })

local NewerValue: Unreadable = table.freeze({ Kind = "Unreadable" :: "Unreadable", Cause = "Newer" :: "Newer" })
local ForeignValue: Unreadable = table.freeze({ Kind = "Unreadable" :: "Unreadable", Cause = "Foreign" :: "Foreign" })

local StateKey = "s"
local BookKey = "b"
local PostKey = "p"
local GivenKey = "r"
local SealKey = "z"

local KeptKeys: { [unknown]: boolean } = {
	[StateKey] = true,
	[BookKey] = true,
	[PostKey] = true,
	[GivenKey] = true,
}
local SealedKeys: { [unknown]: boolean } = {
	[SealKey] = true,
}

local NotATable = "a stored value is not a table"
local FieldsOfAnotherForm = "a stored value holds a field that is not one of its form's"
local FieldNotText = "the field that holds b, a seal or a part's state is not a string"
local StateNotATable = "the field that holds a state is not a table"
local StoredStateWhere = "the stored state"
local ShardNotASum = "the field that holds a shard's state is not a whole number within the sum a shard holds"
local PostOnLedgerKey = "a shard or a part holds p or r, which only a game key holds"
local PackedOnLedgerKey = "b says a shard's or a part's state is packed, which only a game key's can be"
local PackedNotBuffer = "b says the state is packed, and the field that holds it is not a buffer"
local PackedNotJson = "the packed state is not JSON"
local KeyNotOfStore = "a mark or a pinned record names a key that its store cannot hold"
local ModuleName = "Value"
local WriteStateNotATable = `{ModuleName}: a kept value's state and given state are tables. The caller must give tables`
local WritePostOnLedgerKey =
	`{ModuleName}: only a game key holds p and r. The caller must give a shard or a part neither`
local WriteShardNotASum =
	`{ModuleName}: a shard's state holds a whole sum within its limit under {ShardSumField}. The caller must give one`
local WriteStateTooBig =
	`{ModuleName}: a state past {PackedStateMost} bytes of JSON cannot be stored. The caller must refuse it as Full`

local function Base64Length(Bytes: number): number
	return math.ceil(Bytes / Base64GroupBytes) * Base64GroupCharacters
end

local function MeasureOf(State: Fields): Measure
	local Known = Measures[State]
	if Known ~= nil then
		return Known
	end
	local Measured: Measure = { Bytes = Json.Size(State), Packed = nil }
	Measures[State] = Measured
	return Measured
end

local function TakePackedText(State: Fields, Measured: Measure): string
	local Packed = Measured.Packed
	Measured.Packed = nil
	if Packed ~= nil then
		return Packed
	end
	return Json.CanonicalJson(State)
end

local function StateCost(Encoding: Encoding, State: Fields): number?
	local Measured: Measure = { Bytes = Json.Size(State), Packed = nil }
	Measures[State] = Measured
	if Measured.Bytes <= StateCap then
		return Measured.Bytes
	end
	if Measured.Bytes > PackedStateMost then
		return nil
	end
	local Packed = Json.CanonicalJson(State)
	Measured.Packed = Packed
	local Compressed = Encoding.Compress(buffer.fromstring(Packed))
	return BufferFramingBytes + Base64Length(buffer.len(Compressed) + PackedSlackBytes)
end

local function StateFits(Encoding: Encoding, State: Fields, Cap: number): boolean
	local Cost = StateCost(Encoding, State)
	return Cost ~= nil and Cost <= Cap
end

local function IsShardSum(Held: unknown): boolean
	if type(Held) ~= "number" then
		return false
	end
	return Held % 1 == 0 and math.abs(Held) <= Extras.ShardSumMost
end

local function WriteShardSum(State: Fields): unknown
	local Sum = State[ShardSumField]
	if not IsShardSum(Sum) then
		error(WriteShardNotASum)
	end
	return Sum
end

local function WriteGameState(State: Fields): (unknown, StateForm)
	local Measured = MeasureOf(State)
	if Measured.Bytes <= StateCap then
		return State, StateForms.Plain
	end
	if Measured.Bytes > PackedStateMost then
		error(WriteStateTooBig)
	end
	return buffer.fromstring(TakePackedText(State, Measured)), StateForms.Packed
end

local function WriteState(State: Fields, Build: KeyBuild): (unknown, StateForm)
	if Build.KeyKind == KeyKinds.Shard then
		return WriteShardSum(State), StateForms.Plain
	end
	if Build.KeyKind == KeyKinds.Part then
		return Part.TextOfState(State, Build.Balances), StateForms.Plain
	end
	return WriteGameState(State)
end

local function EncodeValue(Value: Value, Build: KeyBuild, WindowUnit: number): { [string]: unknown }
	if Value.Kind == "Sealed" then
		return { [SealKey] = EncodeSeal(Value.Seal) }
	end
	if type(Value.State) ~= "table" then
		error(WriteStateNotATable)
	end
	if Value.Given ~= nil and type(Value.Given) ~= "table" then
		error(WriteStateNotATable)
	end
	if Build.KeyKind ~= KeyKinds.Game and (Value.Post ~= nil or Value.Given ~= nil) then
		error(WritePostOnLedgerKey)
	end
	local Written, Form = WriteState(Value.State, Build)
	local Raw: { [string]: unknown } = { [StateKey] = Written, [BookKey] = EncodeBook(Value.Book, WindowUnit, Form) }
	if Value.Post ~= nil then
		Raw[PostKey] = EncodePost(Value.Post)
	end
	if Value.Given ~= nil then
		Raw[GivenKey] = Value.Given
	end
	return Raw
end

local function RequireOnly(Fields: Fields, Allowed: { [unknown]: boolean })
	for Key in Fields do
		if not Allowed[Key] then
			Malformed(FieldsOfAnotherForm)
		end
	end
end

local function RequireText(Field: unknown): string
	if type(Field) ~= "string" then
		return Malformed(FieldNotText)
	end
	return Field
end

local function RequireState(Field: unknown): Fields
	if type(Field) ~= "table" then
		return Malformed(StateNotATable)
	end
	local Problem = Storable(Field, StoredStateWhere)
	if Problem ~= nil then
		return Malformed(Problem)
	end
	return Field :: Fields
end

local function ReadShardState(Field: unknown): Fields
	if not IsShardSum(Field) then
		return Malformed(ShardNotASum)
	end
	return { [ShardSumField] = Field }
end

local function ReadPackedState(Field: unknown, Encoding: Encoding): Fields
	if type(Field) ~= "buffer" then
		return Malformed(PackedNotBuffer)
	end
	local Parsed, Held = pcall(Encoding.ParseJson, buffer.tostring(Field))
	if not Parsed then
		return Malformed(PackedNotJson)
	end
	return RequireState(Held)
end

local function ReadState(Field: unknown, Build: KeyBuild, Form: StateForm, Encoding: Encoding): Fields
	if Form == StateForms.Packed then
		if Build.KeyKind ~= KeyKinds.Game then
			return Malformed(PackedOnLedgerKey)
		end
		return ReadPackedState(Field, Encoding)
	end
	if Build.KeyKind == KeyKinds.Shard then
		return ReadShardState(Field)
	end
	if Build.KeyKind == KeyKinds.Part then
		return Part.StateOfText(RequireText(Field), Build.Balances)
	end
	return RequireState(Field)
end

local function RequireReferable(Read: Book, Build: KeyBuild)
	local MayReference = Build.MayReference
	if MayReference == nil then
		return
	end
	for _, Item in Read.Work do
		if Item.Kind ~= "Pinned" then
			if not MayReference(Item.Decider) then
				Malformed(KeyNotOfStore)
			end
			continue
		end
		for _, Leg in Item.OtherLegs do
			if not MayReference(Leg) then
				Malformed(KeyNotOfStore)
			end
		end
	end
end

local function ReadValue(Raw: unknown, Build: KeyBuild, WindowUnit: number, Encoding: Encoding): Value
	if type(Raw) ~= "table" then
		return Malformed(NotATable)
	end
	local Fields = Raw :: Fields
	if Fields[SealKey] ~= nil then
		RequireOnly(Fields, SealedKeys)
		return { Kind = "Sealed", Seal = ReadSealText(RequireText(Fields[SealKey])) }
	end
	RequireOnly(Fields, KeptKeys)
	if Build.KeyKind ~= KeyKinds.Game and (Fields[PostKey] ~= nil or Fields[GivenKey] ~= nil) then
		Malformed(PostOnLedgerKey)
	end
	local Read, Form = ReadBookText(RequireText(Fields[BookKey]), WindowUnit)
	RequireReferable(Read, Build)
	return {
		Kind = "Kept",
		State = ReadState(Fields[StateKey], Build, Form, Encoding),
		Book = Read,
		Post = if Fields[PostKey] ~= nil then ReadPost(Fields[PostKey]) else nil,
		Given = if Fields[GivenKey] ~= nil then RequireState(Fields[GivenKey]) else nil,
	}
end

local function DecodeStored(Raw: unknown, Build: KeyBuild, WindowUnit: number, Encoding: Encoding): Decoded
	local Succeeded, Read = pcall(ReadValue, Raw, Build, WindowUnit, Encoding)
	if Succeeded then
		return Read
	end
	if Book.IsNewerFormat(Read) then
		return NewerValue
	end
	return ForeignValue
end

local function DecodeValue(Raw: unknown, Build: KeyBuild, WindowUnit: number, Encoding: Encoding): Value?
	local Decoded = DecodeStored(Raw, Build, WindowUnit, Encoding)
	if Decoded.Kind == "Unreadable" then
		return nil
	end
	return Decoded
end

local function CopyDefault(Default: { [string]: unknown }): Fields
	local State: Fields = {}
	for Field, Held in Default do
		State[Field] = Held
	end
	return State
end

return {
	CopyDefault = CopyDefault,
	StateCost = StateCost,
	StateFits = StateFits,
	EncodeValue = EncodeValue,
	DecodeStored = DecodeStored,
	DecodeValue = DecodeValue,
}
