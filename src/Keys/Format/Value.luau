--!strict
--!optimize 2

--[=[
	Value: a key's value (spec/protocols/record/Format.md 5, 10) as the DataStore table: the state s and its book b, or
	a seal z, and no other keys. A build's key kind says what s is: a table, a shard's integer, a part's text. A game
	state past PackFrom bytes of JSON is stored as a buffer the DataStore compresses, when that is smaller, so its
	stored size never passes its JSON size. A value whose book names a key MayReference refuses is foreign.
	b's windows are in the caller's WindowUnit. The reader throws through Format.Malformed; DecodeValue gives nil and
	DecodeStored the Unreadable cause, Newer or Foreign. A decoded state is frozen and vetted as it is checked, or read
	as a candidate of the same content (StateHashes, SameContent). A written game state is frozen first. Basis is the
	state read, and BasisText its canonical text when that is what was stored.

	Return type: Functions, and the types Value, Kept, Decoded, Unreadable, UnreadableCause, KeyBuild and Candidates.
	Example usage:
		Value.EncodeValue(Kept, Build, Limits.WindowUnit, Setup.Encoding) --> { s = {}, b = "AAAABAAA..." }, 2
--]=]

local Balances = require("../Trades/Balances")
local Book = require("./Book")
local Extras = require("../Constants/Extras")
local Format = require("../Encoding/Format")
local Guards = require("../Ops/Guards")
local HashInputs = require("../Encoding/HashInputs")
local Json = require("../Encoding/Json")
local Names = require("../Encoding/Names")
local Part = require("./Items/Part")
local Post = require("./Post")
local Record = require("../Constants/Record")
local SameContent = require("./SameContent")
local Seal = require("./Items/Seal")
local Splice = require("../Encoding/Splice")
local StateHashes = require("../Encoding/StateHashes")

type Book = Book.Book
type StateForm = Book.StateForm
type Encoding = HashInputs.Encoding
type DiffEntry = Post.DiffEntry
type Arithmetic = Balances.Arithmetic
type KeyKind = Record.KeyKind
type KeyReference = Names.KeyReference

export type Kept = {
	Kind: "Kept",
	State: Fields,
	Book: Book,
	Post: { DiffEntry }?,
	Given: Fields?,
	Basis: Fields?,
	BasisText: buffer?,
}

export type Value = Kept | { Kind: "Sealed", Seal: Seal.Seal }

export type UnreadableCause = "Newer" | "Foreign"

export type Unreadable = { read Kind: "Unreadable", read Cause: UnreadableCause }

export type Decoded = Value | Unreadable

export type Fields = { [unknown]: unknown }

export type Candidates = { Fields }

export type KeyBuild = {
	read KeyKind: KeyKind,
	read Balances: { [string]: Arithmetic },
	read MayReference: ((Reference: KeyReference) -> boolean)?,
}

local Malformed = Format.Malformed
local DeepFreeze = Guards.DeepFreeze
local CheckStorable = Guards.CheckStorable

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
local PackFrom = Record.PackFrom
local PackedStateMost = Record.PackedStateMost
local BufferFramingBytes = Record.BufferFramingBytes
local PackedSlackBytes = Record.PackedSlackBytes
local Base64GroupBytes = 3
local Base64GroupCharacters = 4

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

local function PackedSize(Encoding: Encoding, Text: buffer): number
	local Compressed = Encoding.Compress(Text)
	return BufferFramingBytes + Base64Length(buffer.len(Compressed) + PackedSlackBytes)
end

local function StateCost(Encoding: Encoding, Build: KeyBuild, State: Fields): number?
	local JsonBytes = Json.Size(State)
	if Build.KeyKind ~= KeyKinds.Game then
		return JsonBytes
	end
	if JsonBytes <= StateCap then
		return JsonBytes
	end
	if JsonBytes > PackedStateMost then
		return nil
	end
	return PackedSize(Encoding, buffer.fromstring(Json.CanonicalJson(State)))
end

local function StateFits(Encoding: Encoding, Build: KeyBuild, State: Fields, Cap: number): boolean
	local Cost = StateCost(Encoding, Build, State)
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

local function WriteGameState(
	Encoding: Encoding,
	State: Fields,
	Basis: Fields?,
	BasisText: buffer?
): (unknown, StateForm, number, boolean)
	local JsonBytes = Json.Size(State)
	if JsonBytes <= PackFrom then
		return State, StateForms.Plain, JsonBytes, false
	end
	if JsonBytes > PackedStateMost then
		error(WriteStateTooBig)
	end
	local Text, ReadsBack = Splice.Canonical(State, Basis, BasisText)
	local Packed = PackedSize(Encoding, Text)
	if JsonBytes <= StateCap and JsonBytes <= Packed then
		return State, StateForms.Plain, JsonBytes, false
	end
	return Text, StateForms.Packed, Packed, ReadsBack
end

local function WriteState(
	State: Fields,
	Build: KeyBuild,
	Encoding: Encoding,
	Basis: Fields?,
	BasisText: buffer?
): (unknown, StateForm, number, boolean)
	if Build.KeyKind == KeyKinds.Shard then
		local Sum = WriteShardSum(State)
		return Sum, StateForms.Plain, Json.Size(Sum), false
	end
	if Build.KeyKind == KeyKinds.Part then
		local Text = Part.TextOfState(State, Build.Balances)
		return Text, StateForms.Plain, Json.Size(Text), false
	end
	return WriteGameState(Encoding, State, Basis, BasisText)
end

local function StoredBytes(Encoding: Encoding, Build: KeyBuild, State: Fields): number
	local _, _, Bytes = WriteState(State, Build, Encoding, nil, nil)
	return Bytes
end

local function EncodeValue(
	Value: Value,
	Build: KeyBuild,
	WindowUnit: number,
	Encoding: Encoding
): ({ [string]: unknown }, number?)
	if Value.Kind == "Sealed" then
		return { [SealKey] = EncodeSeal(Value.Seal) }, nil
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
	if Build.KeyKind == KeyKinds.Game then
		DeepFreeze(Value.State)
	end
	local Written, Form, StateBytes, ReadsBack = WriteState(Value.State, Build, Encoding, Value.Basis, Value.BasisText)
	if type(Written) == "buffer" then
		StateHashes.KeepWritten(Value.State, buffer.len(Written), Encoding.Blake3(Written), ReadsBack)
	end
	local Raw: { [string]: unknown } = { [StateKey] = Written, [BookKey] = EncodeBook(Value.Book, WindowUnit, Form) }
	if Value.Post ~= nil then
		Raw[PostKey] = EncodePost(Value.Post)
	end
	if Value.Given ~= nil then
		Raw[GivenKey] = Value.Given
	end
	return Raw, StateBytes
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
	DeepFreeze(Field)
	local Problem = CheckStorable(Field, StoredStateWhere)
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

local function SameAsCandidate(Field: unknown, Candidates: Candidates?): Fields?
	if Candidates == nil then
		return nil
	end
	for _, Candidate in Candidates do
		local Same = SameContent.Matching(Field, Candidate)
		if Same ~= nil then
			return Same
		end
	end
	return nil
end

local function ReadGameState(Field: unknown, Candidates: Candidates?): Fields
	local Same = SameAsCandidate(Field, Candidates)
	if Same ~= nil then
		return Same
	end
	return RequireState(Field)
end

local function ReadPackedState(Field: unknown, Encoding: Encoding, Candidates: Candidates?): (Fields, buffer?)
	if type(Field) ~= "buffer" then
		return Malformed(PackedNotBuffer), nil
	end
	local Bytes = buffer.len(Field)
	local Digest = Encoding.Blake3(Field)
	local Held, IsCanonical = StateHashes.Match(Candidates, Bytes, Digest)
	if Held ~= nil then
		return Held, if IsCanonical then Field else nil
	end
	local Parsed, Decoded = pcall(Encoding.ParseJson, buffer.tostring(Field))
	if not Parsed then
		return Malformed(PackedNotJson), nil
	end
	local State = ReadGameState(Decoded, Candidates)
	if State == Decoded then
		StateHashes.KeepRead(State, Bytes, Digest)
	end
	return State, nil
end

local function ReadState(
	Field: unknown,
	Build: KeyBuild,
	Form: StateForm,
	Encoding: Encoding,
	Candidates: Candidates?
): (Fields, buffer?)
	if Form == StateForms.Packed then
		if Build.KeyKind ~= KeyKinds.Game then
			return Malformed(PackedOnLedgerKey), nil
		end
		return ReadPackedState(Field, Encoding, Candidates)
	end
	if Build.KeyKind == KeyKinds.Shard then
		return ReadShardState(Field), nil
	end
	if Build.KeyKind == KeyKinds.Part then
		return Part.StateOfText(RequireText(Field), Build.Balances), nil
	end
	return ReadGameState(Field, Candidates), nil
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

local function ReadValue(
	Raw: unknown,
	Build: KeyBuild,
	WindowUnit: number,
	Encoding: Encoding,
	Candidates: Candidates?
): Value
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
	local State, StateText = ReadState(Fields[StateKey], Build, Form, Encoding, Candidates)
	return {
		Kind = "Kept",
		State = State,
		Basis = State,
		BasisText = StateText,
		Book = Read,
		Post = if Fields[PostKey] ~= nil then ReadPost(Fields[PostKey]) else nil,
		Given = if Fields[GivenKey] ~= nil then RequireState(Fields[GivenKey]) else nil,
	}
end

local function DecodeStored(
	Raw: unknown,
	Build: KeyBuild,
	WindowUnit: number,
	Encoding: Encoding,
	Candidates: Candidates?
): Decoded
	local Succeeded, Read = pcall(ReadValue, Raw, Build, WindowUnit, Encoding, Candidates)
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
	StoredBytes = StoredBytes,
	StateFits = StateFits,
	EncodeValue = EncodeValue,
	DecodeStored = DecodeStored,
	DecodeValue = DecodeValue,
}
