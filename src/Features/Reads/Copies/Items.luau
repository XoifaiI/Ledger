--!strict
--!optimize 2
--!native

--[=[
	Items: the copy items of one followed key (extras sheet E7; Format 11, 12) on each of its replicas: a replica's
	header key (replica 0 the tagged key with the key's length, replica r named by Spread), its parts' keys and map,
	both values' codecs, whether a header fits ItemRoom, a state's JSON cut into pieces at characters, and the commands
	that get or remove items. A header carries the copy's replica count and how many replicas were written at its q,
	from 1 to the replica count. Every replica's items sit in the map its own header key hashes to. A malformed item
	reads as nothing.

	Return type: A plain table of functions, and the DecodedHeader type.
	Example usage:
		local Key = Items.HeaderKey(Encoding, { Store = "Players", Scope = "global", Key = "Alice" }, 0)
		local Pieces = Items.CutPieces(Json.CanonicalJson(State), Q, Level) --> nil when the state is big
--]=]

local Check = require("../../../Keys/Encoding/Check")
local Events = require("../../../Shared/Events")
local Extras = require("../../../Keys/Constants/Extras")
local ExtrasShapes = require("../../../Shared/ReadShapes")
local HashInputs = require("../../../Keys/Encoding/HashInputs")
local Json = require("../../../Keys/Encoding/Json")
local Names = require("../../../Keys/Encoding/Names")
local Numbers = require("../../../Keys/DataStore/Numbers")
local Record = require("../../../Keys/Constants/Record")
local Shapes = require("../../../Shared/Shapes")
local Spread = require("../Spread")
local Summary = require("../Totals/Summary")

type Command = Events.Command
type MemoryRemoveCommand = Events.MemoryRemoveCommand
type Encoding = HashInputs.Encoding
type StoreKey = Names.StoreKey
type CopyBody = ExtrasShapes.CopyBody
type CopyHeader = ExtrasShapes.CopyHeader
type CopyPart = ExtrasShapes.CopyPart
type ServerState = Shapes.ServerState
type Fields = { [unknown]: unknown }
export type DecodedHeader =
	{ read Kind: "Header", read Header: CopyHeader }
	| { read Kind: "Behind" }
	| { read Kind: "Unreadable" }

local QKey = "q"
local LevelKey = "g"
local FloorKey = "f"
local IncarnationKey = "i"
local NoIncarnationMark = 0
local StateKey = "s"
local PartsKey = "p"
local BigKey = "big"
local PieceKey = "d"
local BigMark = 1

local BigBody: CopyBody = table.freeze({ Kind = "Big" :: "Big" })
local BehindHeader: DecodedHeader = table.freeze({ Kind = "Behind" :: "Behind" })
local UnreadableHeader: DecodedHeader = table.freeze({ Kind = "Unreadable" :: "Unreadable" })

local ContinuationMask = 0xC0
local ContinuationBits = 0x80

local EmptyPiece = ""
local ByteValueCount = 2 ^ Record.BitsPerByte

local JsonBytesOfByte = buffer.create(ByteValueCount)
for Byte = 0, ByteValueCount - 1 do
	buffer.writeu8(JsonBytesOfByte, Byte, Json.Size(string.char(Byte)) - Json.Size(EmptyPiece))
end

local VersionKey = Record.ItemVersionKey
local HolderKey = Record.ItemHolderKey
local UntilKey = Record.ItemUntilKey
local AtKey = Record.ItemAtKey
local ReplicasKey = Record.ItemReplicasKey
local WrittenKey = Record.ItemWrittenKey
local CopyKeyPrefix = Record.CopyKeyPrefix
local CopyMapPrefix = Record.CopyMapPrefix
local CopyVersion = Record.CopyVersion
local PartsMax = Record.PartsMax
local ItemRoom = Extras.ItemRoom
local CopySlots = Extras.CopySlots

local IsPartCount = Check.Whole(1, PartsMax)

local Faults = table.freeze({
	BodyTwice = "the item holds more than one body",
	BodyMissing = "the item holds no body",
	NotBigMark = "a big body is not marked as one",
	WrittenAboveReplicas = "more replicas were written than there are",
	PieceNotText = "a part's piece is not text",
})

local function ReadState(Held: unknown): CopyBody
	if type(Held) ~= "table" then
		return Summary.Malformed(Summary.Faults.NotATable)
	end
	return { Kind = "State", State = Held :: Fields }
end

local function ReadParts(Held: unknown): CopyBody
	return { Kind = "Parts", Count = Summary.ReadWhole(Held, IsPartCount) }
end

local function ReadBig(Held: unknown): CopyBody
	if Held ~= BigMark then
		return Summary.Malformed(Faults.NotBigMark)
	end
	return BigBody
end

local BodyReaders: { [string]: (Held: unknown) -> CopyBody } = {
	[StateKey] = ReadState,
	[PartsKey] = ReadParts,
	[BigKey] = ReadBig,
}

local function ReadBody(Item: Fields): CopyBody
	local Body: CopyBody? = nil
	for Key, Read in BodyReaders do
		local Held = Item[Key]
		if Held == nil then
			continue
		end
		if Body ~= nil then
			return Summary.Malformed(Faults.BodyTwice)
		end
		Body = Read(Held)
	end
	if Body == nil then
		return Summary.Malformed(Faults.BodyMissing)
	end
	return Body
end

local function HeaderKey(Encoding: Encoding, Key: StoreKey, Replica: number): string
	local First = `{CopyKeyPrefix}{Summary.TagOf(Encoding, Key.Store, Key.Scope)}/{#Key.Key}:{Key.Key}`
	return Spread.ReplicaKey(First, Replica)
end

local function PartKey(KeyOfHeader: string, Q: number, Index: number): string
	return `{KeyOfHeader}/{Q % CopySlots}/{Index}`
end

local function CopyMap(Encoding: Encoding, KeyOfHeader: string): string
	return Summary.MapOf(Encoding, CopyMapPrefix, KeyOfHeader)
end

local function GetCommand(Encoding: Encoding, KeyOfHeader: string, ItemKey: string, RequestId: number): Command
	return { Kind = "MemoryGet", RequestId = RequestId, Map = CopyMap(Encoding, KeyOfHeader), Key = ItemKey }
end

local function EncodeHeader(Header: CopyHeader): Fields
	local Stamp = Header.HolderStamp
	local Item: Fields = {
		[VersionKey] = CopyVersion,
		[QKey] = Header.Q,
		[LevelKey] = Header.Level,
		[FloorKey] = Header.Floor,
		[HolderKey] = Stamp.HolderNumber,
		[UntilKey] = Stamp.Until,
		[AtKey] = Stamp.At,
		[ReplicasKey] = Header.Replicas,
		[WrittenKey] = Header.Written,
	}
	local Incarnation = Header.Incarnation
	if Incarnation == false then
		Item[IncarnationKey] = NoIncarnationMark
	elseif Incarnation ~= nil then
		Item[IncarnationKey] = { Incarnation.Server, Incarnation.Counter }
	end
	local Body = Header.Body
	if Body.Kind == "State" then
		Item[StateKey] = Body.State
	elseif Body.Kind == "Parts" then
		Item[PartsKey] = Body.Count
	else
		Item[BigKey] = BigMark
	end
	return Item
end

local function ReadIncarnation(Held: unknown): ExtrasShapes.CopyIncarnation
	if Held == nil then
		return nil
	end
	if Held == NoIncarnationMark then
		return false
	end
	if type(Held) ~= "table" then
		return Summary.Malformed(Summary.Faults.NotATable)
	end
	local Pair = Held :: Fields
	return { Server = Summary.ReadPlain(Pair[1]), Counter = Summary.ReadPlain(Pair[2]) }
end

local function ReadStoredHeader(Raw: unknown): DecodedHeader
	if type(Raw) ~= "table" then
		return Summary.Malformed(Summary.Faults.NotATable)
	end
	local Item = Raw :: Fields
	local Version = Item[VersionKey]
	if type(Version) == "number" and Version > CopyVersion then
		return BehindHeader
	end
	if Version ~= CopyVersion then
		return Summary.Malformed(Summary.Faults.WrongVersion)
	end
	local Header: CopyHeader = {
		Q = Summary.ReadPlain(Item[QKey]),
		Level = Summary.ReadPlain(Item[LevelKey]),
		Floor = Summary.ReadPlain(Item[FloorKey]),
		Incarnation = ReadIncarnation(Item[IncarnationKey]),
		HolderStamp = Summary.ReadHolderStamp(Item),
		Body = ReadBody(Item),
		Replicas = Summary.ReadWhole(Item[ReplicasKey], Spread.IsReplicaCount),
		Written = Summary.ReadWhole(Item[WrittenKey], Spread.IsReplicaCount),
	}
	if Header.Written > Header.Replicas then
		return Summary.Malformed(Faults.WrittenAboveReplicas)
	end
	return { Kind = "Header", Header = Header }
end

local function DecodeHeader(Raw: unknown): DecodedHeader
	local IsRead, Read = pcall(ReadStoredHeader, Raw)
	if not IsRead then
		return UnreadableHeader
	end
	return Read
end

local function EncodePart(Part: CopyPart): Fields
	return {
		[QKey] = Part.Q,
		[LevelKey] = Part.Level,
		[PieceKey] = Part.Piece,
	}
end

local function ReadPart(Raw: unknown): CopyPart
	if type(Raw) ~= "table" then
		return Summary.Malformed(Summary.Faults.NotATable)
	end
	local Item = Raw :: Fields
	local Piece = Item[PieceKey]
	if type(Piece) ~= "string" then
		return Summary.Malformed(Faults.PieceNotText)
	end
	return { Q = Summary.ReadPlain(Item[QKey]), Level = Summary.ReadPlain(Item[LevelKey]), Piece = Piece }
end

local function DecodePart(Raw: unknown): CopyPart?
	local IsRead, Read = pcall(ReadPart, Raw)
	if not IsRead then
		return nil
	end
	return Read
end

local function Fits(Header: CopyHeader): boolean
	return Json.Size(EncodeHeader(Header)) <= ItemRoom
end

local function LongestPiece(Text: string, From: number, Q: number, Level: number): number
	local Room = ItemRoom - Json.Size(EncodePart({ Q = Q, Level = Level, Piece = EmptyPiece }))
	local Used = 0
	for Index = From, string.len(Text) do
		local Byte = string.byte(Text, Index)
		Used += buffer.readu8(JsonBytesOfByte, Byte)
		if Used > Room then
			return Index - From
		end
	end
	return string.len(Text) - From + 1
end

local function IsContinuation(Byte: number): boolean
	return bit32.band(Byte, ContinuationMask) == ContinuationBits
end

local function CutPieces(Text: string, Q: number, Level: number): { string }?
	local Pieces: { string } = {}
	local From = 1
	while From <= #Text and #Pieces < PartsMax do
		local Next = From + LongestPiece(Text, From, Q, Level)
		while Next <= #Text and IsContinuation(string.byte(Text, Next)) do
			Next -= 1
		end
		table.insert(Pieces, string.sub(Text, From, Next - 1))
		From = Next
	end
	if From <= #Text then
		return nil
	end
	return Pieces
end

local function JoinPieces(Parts: { CopyPart }): string
	local Pieces: { string } = {}
	for Index, Part in Parts do
		Pieces[Index] = Part.Piece
	end
	return table.concat(Pieces)
end

local function ReplicaKeys(Header: string): { string }
	local Keys: { string } = { Header }
	for Slot = 0, CopySlots - 1 do
		for Index = 0, PartsMax - 1 do
			table.insert(Keys, PartKey(Header, Slot, Index))
		end
	end
	return Keys
end

local function RemoveCommands(Server: ServerState, Key: StoreKey, Replicas: number): { MemoryRemoveCommand }
	local Encoding = Server.Encoding
	local Removals: { MemoryRemoveCommand } = {}
	for Replica = 0, Replicas - 1 do
		local Header = HeaderKey(Encoding, Key, Replica)
		local Map = CopyMap(Encoding, Header)
		for _, ItemKey in ReplicaKeys(Header) do
			local Remove: MemoryRemoveCommand =
				{ Kind = "MemoryRemove", RequestId = Numbers.NewRequestId(Server), Map = Map, Key = ItemKey }
			table.insert(Removals, Remove)
		end
	end
	return Removals
end

return {
	HeaderKey = HeaderKey,
	PartKey = PartKey,
	CopyMap = CopyMap,
	GetCommand = GetCommand,
	EncodeHeader = EncodeHeader,
	DecodeHeader = DecodeHeader,
	EncodePart = EncodePart,
	DecodePart = DecodePart,
	Fits = Fits,
	CutPieces = CutPieces,
	JoinPieces = JoinPieces,
	RemoveCommands = RemoveCommands,
}
