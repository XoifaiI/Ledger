--!strict
--!optimize 2
--!native

--[=[
	Names: the strings of the record's alphabet text (spec/protocols/record/Format.md 3) on buffers: stored
	strings, names, a take's sub name and key references.

	A body outside the alphabet is base64url behind a flag. The reader takes only what the writer would
	write, and throws through Format.Malformed. A SubName is the stored pair; OpName.Part is the same part on an
	op's name.

	Return type: A plain table of functions (KeyText gives the full key reference of a StoreKey as the text that
	keys a table), and the Name, GameOpName, OpName, NameWithPart, GivenName, SubName, KeyReference and StoreKey
	types. An OpName is a game name with its fingerprint or a drawn name; either carries the part of a sub name
	when it has one. A StoreKey is the store, scope and key a command targets.
	Example usage:
		local Out = Format.NewWriter(64)
		Names.WriteStored(Out, "Alice_42")
		Format.ToString(Out) --> "PAlice_42"
--]=]

local Alphabet = require("./Alphabet")
local Format = require("./Format")
local Messages = require("../Constants/Messages")
local Record = require("../Constants/Record")

type Writer = Format.Writer
type Reader = Format.Reader

export type Name = { Kind: "Game", Text: string } | { Kind: "Drawn", Server: number, Counter: number }

export type GameOpName = { read Kind: "Game", read Text: string, read Fingerprint: number, read Part: number? }

export type OpName = GameOpName | { read Kind: "Drawn", read Server: number, read Counter: number, read Part: number? }

export type NameWithPart = (Name | OpName) & { read Part: number? }

export type GivenName =
	{ read Kind: "Game", read Text: string, read Stamp: number? }
	| { read Kind: "Drawn", read Server: number, read Counter: number, read Stamp: number }

export type SubName = {
	Name: Name,
	Part: number,
}

export type KeyReference = { Kind: "Short", Key: string } | { Kind: "Full", Store: string, Scope: string, Key: string }

export type StoreKey = {
	Store: string,
	Scope: string,
	Key: string,
}

local Values = Alphabet.Values
local Chars = Alphabet.Chars
local INVALID = Alphabet.INVALID

local Grow = Format.Grow
local Malformed = Format.Malformed
local WriteVarint = Format.WriteVarint
local ReadVarint = Format.ReadVarint
local WriteCharacter = Format.WriteCharacter
local ReadCharacter = Format.ReadCharacter

local AlphabetSize = #Record.Alphabet
local CharacterMask = AlphabetSize - 1
local CharacterBits = math.log(AlphabetSize, 2)

local BitsPerByte = Record.BitsPerByte
local ByteMask = 2 ^ BitsPerByte - 1

local KeyTextStartBytes = 64

local BytesPerGroup = 3
local CharactersPerGroup = 4
local BytesAfterFirst = BytesPerGroup - 1
local CharactersAfterFirst = CharactersPerGroup - 1
local LongTailBytes = BytesPerGroup - 1
local LongTailCharacters = CharactersPerGroup - 1
local FirstByteShift = BytesAfterFirst * BitsPerByte
local SecondByteShift = BitsPerByte
local FirstCharacterShift = CharactersAfterFirst * CharacterBits
local SecondCharacterShift = (CharactersAfterFirst - 1) * CharacterBits
local ThirdCharacterShift = CharacterBits

local StoredFormCount = 2
local NameMax = Record.NameMax
local UnstoredGameBytes = NameMax // CharactersPerGroup * BytesPerGroup

local ShortFormByte = string.byte("A")
local FullFormByte = string.byte("B")
local ShortFormIndex = buffer.readu8(Values, ShortFormByte)
local FullFormIndex = buffer.readu8(Values, FullFormByte)

local EmptyStoredString = "Names: an empty string cannot be stored. The call that would store one must throw first"
local StoredStringNotUtf8 =
	"Names: a string that is not valid UTF-8 cannot be stored. The call that would store one must throw first"
local ImpossibleBase64Length = "a base64url body is one character more than a whole group, which no text gives"
local StrayBase64Bits = "a base64url body has trailing bits that are not zero"
local Base64OfAlphabetText = "a base64url body decodes to alphabet characters only, "
	.. "which the writer stores as they are"
local Base64NotUtf8 = "a base64url body decodes to bytes that are not valid UTF-8"
local DrawnHeaderOfString = "a stored string starts with 0, which marks a drawn name"
local UnknownKeyForm = "a key reference starts with a character that is neither of its two forms"

local function IsAlphabetBytes(Bytes: buffer, At: number, Length: number): boolean
	for Offset = At, At + Length - 1 do
		if buffer.readu8(Values, buffer.readu8(Bytes, Offset)) == INVALID then
			return false
		end
	end
	return true
end

local function IsAlphabetText(Text: string): boolean
	for Index = 1, #Text do
		local Byte = string.byte(Text, Index)
		if buffer.readu8(Values, Byte) == INVALID then
			return false
		end
	end
	return true
end

local function StoredHeader(BodyLength: number, IsBase64: boolean): number
	local Form = if IsBase64 then 1 else 0
	return StoredFormCount * (BodyLength - 1) + Form + 1
end

local function PutAlphabetBody(Out: Writer, Text: string): boolean
	local Cursor = Out.Cursor
	local Length = #Text
	if Cursor + Length > Out.Size then
		Grow(Out, Cursor, Length)
	end
	local Buffer = Out.Buffer
	buffer.writestring(Buffer, Cursor, Text)
	if not IsAlphabetBytes(Buffer, Cursor, Length) then
		return false
	end
	Out.Cursor = Cursor + Length
	return true
end

local function Base64UrlLength(ByteCount: number): number
	return (ByteCount * CharactersPerGroup + BytesPerGroup - 1) // BytesPerGroup
end

local function PutBase64Url(Out: Writer, Text: string)
	local Length = #Text
	local Encoded = Base64UrlLength(Length)
	local Cursor = Out.Cursor
	local Staged = Cursor + Encoded
	if Staged + Length > Out.Size then
		Grow(Out, Cursor, Encoded + Length)
	end
	local Buffer = Out.Buffer
	buffer.writestring(Buffer, Staged, Text)

	local Groups = Length // BytesPerGroup
	for Group = 0, Groups - 1 do
		local From = Staged + Group * BytesPerGroup
		local To = Cursor + Group * CharactersPerGroup
		local First = bit32.lshift(buffer.readu8(Buffer, From), FirstByteShift)
		local Second = bit32.lshift(buffer.readu8(Buffer, From + 1), SecondByteShift)
		local Bits = bit32.bor(First, Second, buffer.readu8(Buffer, From + 2))
		local FirstIndex = bit32.rshift(Bits, FirstCharacterShift)
		local SecondIndex = bit32.band(bit32.rshift(Bits, SecondCharacterShift), CharacterMask)
		local ThirdIndex = bit32.band(bit32.rshift(Bits, ThirdCharacterShift), CharacterMask)
		local FourthIndex = bit32.band(Bits, CharacterMask)
		buffer.writeu8(Buffer, To, buffer.readu8(Chars, FirstIndex))
		buffer.writeu8(Buffer, To + 1, buffer.readu8(Chars, SecondIndex))
		buffer.writeu8(Buffer, To + 2, buffer.readu8(Chars, ThirdIndex))
		buffer.writeu8(Buffer, To + 3, buffer.readu8(Chars, FourthIndex))
	end

	local Left = Length % BytesPerGroup
	if Left > 0 then
		local From = Staged + Groups * BytesPerGroup
		local To = Cursor + Groups * CharactersPerGroup
		local First = bit32.lshift(buffer.readu8(Buffer, From), FirstByteShift)
		local Second = if Left == LongTailBytes
			then bit32.lshift(buffer.readu8(Buffer, From + 1), SecondByteShift)
			else 0
		local Bits = bit32.bor(First, Second)
		local FirstIndex = bit32.rshift(Bits, FirstCharacterShift)
		local SecondIndex = bit32.band(bit32.rshift(Bits, SecondCharacterShift), CharacterMask)
		local ThirdIndex = bit32.band(bit32.rshift(Bits, ThirdCharacterShift), CharacterMask)
		buffer.writeu8(Buffer, To, buffer.readu8(Chars, FirstIndex))
		buffer.writeu8(Buffer, To + 1, buffer.readu8(Chars, SecondIndex))
		if Left == LongTailBytes then
			buffer.writeu8(Buffer, To + 2, buffer.readu8(Chars, ThirdIndex))
		end
	end
	Out.Cursor = Cursor + Encoded
end

local function WriteStored(Out: Writer, Text: string)
	if Text == "" then
		error(EmptyStoredString)
	end
	local Start = Out.Cursor
	WriteVarint(Out, StoredHeader(#Text, false))
	if PutAlphabetBody(Out, Text) then
		return
	end
	Out.Cursor = Start
	if utf8.len(Text) == nil then
		error(StoredStringNotUtf8)
	end
	WriteVarint(Out, StoredHeader(Base64UrlLength(#Text), true))
	PutBase64Url(Out, Text)
end

local function ReadAlphabetBody(Bytes: buffer, At: number, Length: number): string
	if not IsAlphabetBytes(Bytes, At, Length) then
		Malformed(Messages.OutsideAlphabet)
	end
	return buffer.readstring(Bytes, At, Length)
end

local function DecodeBase64Url(Bytes: buffer, At: number, Length: number): string
	local Remainder = Length % CharactersPerGroup
	if Remainder == 1 then
		Malformed(ImpossibleBase64Length)
	end
	local Groups = Length // CharactersPerGroup
	local DecodedLength = Groups * BytesPerGroup + math.max(Remainder - 1, 0)
	local Decoded = buffer.create(DecodedLength)
	local Written = 0
	for Group = 0, Groups - 1 do
		local From = At + Group * CharactersPerGroup
		local FirstIndex = buffer.readu8(Values, buffer.readu8(Bytes, From))
		local SecondIndex = buffer.readu8(Values, buffer.readu8(Bytes, From + 1))
		local ThirdIndex = buffer.readu8(Values, buffer.readu8(Bytes, From + 2))
		local FourthIndex = buffer.readu8(Values, buffer.readu8(Bytes, From + 3))
		if bit32.bor(FirstIndex, SecondIndex, ThirdIndex, FourthIndex) > CharacterMask then
			Malformed(Messages.OutsideAlphabet)
		end
		local Bits = bit32.bor(
			bit32.lshift(FirstIndex, FirstCharacterShift),
			bit32.lshift(SecondIndex, SecondCharacterShift),
			bit32.lshift(ThirdIndex, ThirdCharacterShift),
			FourthIndex
		)
		buffer.writeu8(Decoded, Written, bit32.rshift(Bits, FirstByteShift))
		buffer.writeu8(Decoded, Written + 1, bit32.band(bit32.rshift(Bits, SecondByteShift), ByteMask))
		buffer.writeu8(Decoded, Written + 2, bit32.band(Bits, ByteMask))
		Written += BytesPerGroup
	end

	if Remainder > 0 then
		local From = At + Groups * CharactersPerGroup
		local FirstIndex = buffer.readu8(Values, buffer.readu8(Bytes, From))
		local SecondIndex = buffer.readu8(Values, buffer.readu8(Bytes, From + 1))
		local ThirdIndex = 0
		if Remainder == LongTailCharacters then
			ThirdIndex = buffer.readu8(Values, buffer.readu8(Bytes, From + 2))
		end
		if bit32.bor(FirstIndex, SecondIndex, ThirdIndex) > CharacterMask then
			Malformed(Messages.OutsideAlphabet)
		end
		local Bits = bit32.bor(
			bit32.lshift(FirstIndex, FirstCharacterShift),
			bit32.lshift(SecondIndex, SecondCharacterShift),
			bit32.lshift(ThirdIndex, ThirdCharacterShift)
		)
		local SecondByte = bit32.band(bit32.rshift(Bits, SecondByteShift), ByteMask)
		local ThirdByte = bit32.band(Bits, ByteMask)
		buffer.writeu8(Decoded, Written, bit32.rshift(Bits, FirstByteShift))
		if Remainder == LongTailCharacters then
			buffer.writeu8(Decoded, Written + 1, SecondByte)
		end
		local StrayBits = if Remainder == LongTailCharacters then ThirdByte else bit32.bor(SecondByte, ThirdByte)
		if StrayBits ~= 0 then
			Malformed(StrayBase64Bits)
		end
	end

	if IsAlphabetBytes(Decoded, 0, DecodedLength) then
		Malformed(Base64OfAlphabetText)
	end
	local Text = buffer.tostring(Decoded)
	if utf8.len(Text) == nil then
		Malformed(Base64NotUtf8)
	end
	return Text
end

local function ReadStoredBody(In: Reader, Header: number): string
	local Form = (Header - 1) % StoredFormCount
	local Length = (Header - 1) // StoredFormCount + 1
	local At = In.At
	local Bytes = In.Bytes
	if At + Length > buffer.len(Bytes) then
		Malformed(Messages.EndsEarly)
	end
	In.At = At + Length
	if Form == 0 then
		return ReadAlphabetBody(Bytes, At, Length)
	end
	return DecodeBase64Url(Bytes, At, Length)
end

local function ReadStored(In: Reader): string
	local Header = ReadVarint(In)
	if Header == 0 then
		Malformed(DrawnHeaderOfString)
	end
	return ReadStoredBody(In, Header)
end

local function FitsName(Text: string): boolean
	if Text == "" then
		return false
	end
	if IsAlphabetText(Text) then
		return #Text <= NameMax
	end
	return #Text <= UnstoredGameBytes
end

local function WriteName(Out: Writer, Name: Name)
	if Name.Kind == "Game" then
		WriteStored(Out, Name.Text)
		return
	end
	WriteVarint(Out, 0)
	WriteVarint(Out, Name.Server)
	WriteVarint(Out, Name.Counter)
end

local function ReadName(In: Reader): Name
	local Header = ReadVarint(In)
	if Header ~= 0 then
		return { Kind = "Game", Text = ReadStoredBody(In, Header) }
	end
	return { Kind = "Drawn", Server = ReadVarint(In), Counter = ReadVarint(In) }
end

local function WriteSubName(Out: Writer, Name: Name, Part: number)
	WriteName(Out, Name)
	WriteCharacter(Out, Part)
end

local function ReadSubName(In: Reader): SubName
	return { Name = ReadName(In), Part = ReadCharacter(In) }
end

local function WithPart(Name: OpName, Part: number?): OpName
	if Name.Kind == "Game" then
		return { Kind = "Game", Text = Name.Text, Fingerprint = Name.Fingerprint, Part = Part }
	end
	return { Kind = "Drawn", Server = Name.Server, Counter = Name.Counter, Part = Part }
end

local function WriteKey(Out: Writer, Reference: KeyReference)
	if Reference.Kind == "Short" then
		WriteStored(Out, Reference.Key)
		return
	end
	WriteStored(Out, Reference.Store)
	WriteStored(Out, Reference.Scope)
	WriteStored(Out, Reference.Key)
end

local function KeyText(Key: StoreKey): string
	local Out = Format.NewWriter(KeyTextStartBytes)
	WriteKey(Out, { Kind = "Full", Store = Key.Store, Scope = Key.Scope, Key = Key.Key })
	return Format.ToString(Out)
end

local function ReferenceTo(From: StoreKey, To: StoreKey): KeyReference
	if To.Store == From.Store and To.Scope == From.Scope then
		return { Kind = "Short", Key = To.Key }
	end
	return { Kind = "Full", Store = To.Store, Scope = To.Scope, Key = To.Key }
end

local function KeyOfReference(From: StoreKey, Reference: KeyReference): StoreKey
	if Reference.Kind == "Short" then
		return { Store = From.Store, Scope = From.Scope, Key = Reference.Key }
	end
	return { Store = Reference.Store, Scope = Reference.Scope, Key = Reference.Key }
end

local function ReadShortKey(In: Reader): KeyReference
	return { Kind = "Short", Key = ReadStored(In) }
end

local function ReadFullKey(In: Reader): KeyReference
	return { Kind = "Full", Store = ReadStored(In), Scope = ReadStored(In), Key = ReadStored(In) }
end

local function WriteTaggedKey(Out: Writer, Reference: KeyReference)
	if Reference.Kind == "Short" then
		WriteCharacter(Out, ShortFormIndex)
	else
		WriteCharacter(Out, FullFormIndex)
	end
	WriteKey(Out, Reference)
end

local function ReadTaggedKey(In: Reader): KeyReference
	local Form = ReadCharacter(In)
	if Form == ShortFormIndex then
		return ReadShortKey(In)
	end
	if Form == FullFormIndex then
		return ReadFullKey(In)
	end
	return Malformed(UnknownKeyForm)
end

return {
	WriteStored = WriteStored,
	ReadStored = ReadStored,
	FitsName = FitsName,
	WriteName = WriteName,
	ReadName = ReadName,
	WriteSubName = WriteSubName,
	ReadSubName = ReadSubName,
	WithPart = WithPart,
	WriteKey = WriteKey,
	KeyText = KeyText,
	ReferenceTo = ReferenceTo,
	KeyOfReference = KeyOfReference,
	ReadShortKey = ReadShortKey,
	ReadFullKey = ReadFullKey,
	WriteTaggedKey = WriteTaggedKey,
	ReadTaggedKey = ReadTaggedKey,
}
