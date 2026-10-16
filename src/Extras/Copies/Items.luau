--!strict
--!optimize 2

--[=[
	Items: the copy items of one followed key (extras sheet E7; Format 11, 12): the header's key (tagged, with the
	key's length), its parts' keys and map, both values' codecs, whether a header fits ItemRoom, a state's JSON cut
	into pieces at characters, and the commands that get or remove items. A malformed item reads as nothing.

	Return type: A plain table of functions, and the DecodedHeader type.
	Example usage:
		local Key = Items.HeaderKey(Encoding, { Store = "Players", Scope = "global", Key = "Alice" })
		local Pieces = Items.CutPieces(Json.CanonicalJson(State), Q, Level) --> nil when the state is big
--]=]

local Check = require("../../Encoding/Check")
local Events = require("../../Events")
local Extras = require("../../Constants/Extras")
local ExtrasShapes = require("../Shapes")
local HashInputs = require("../../Encoding/HashInputs")
local Json = require("../../Encoding/Json")
local Names = require("../../Encoding/Names")
local Numbers = require("../../Writing/Numbers")
local Record = require("../../Constants/Record")
local Shapes = require("../../Shapes")
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

local VersionKey = Record.ItemVersionKey
local HolderKey = Record.ItemHolderKey
local UntilKey = Record.ItemUntilKey
local AtKey = Record.ItemAtKey
local CopyKeyPrefix = Record.CopyKeyPrefix
local CopyMapPrefix = Record.CopyMapPrefix
local CopyVersion = Record.CopyVersion
local PartsMax = Record.PartsMax
local ItemRoom = Extras.ItemRoom
local CopySlots = Extras.CopySlots

local IsPartCount = Check.Whole(1, PartsMax)

local function ReadState(Held: unknown): CopyBody?
	if type(Held) ~= "table" then
		return nil
	end
	return { Kind = "State", State = Held :: Fields }
end

local function ReadParts(Held: unknown): CopyBody?
	if type(Held) ~= "number" or IsPartCount(Held) ~= nil then
		return nil
	end
	return { Kind = "Parts", Count = Held }
end

local function ReadBig(Held: unknown): CopyBody?
	if Held ~= BigMark then
		return nil
	end
	return BigBody
end

local BodyReaders: { [string]: (Held: unknown) -> CopyBody? } = {
	[StateKey] = ReadState,
	[PartsKey] = ReadParts,
	[BigKey] = ReadBig,
}

local function DecodeBody(Item: Fields): CopyBody?
	local Body: CopyBody? = nil
	local Found = 0
	for Key, Read in BodyReaders do
		local Held = Item[Key]
		if Held ~= nil then
			Found += 1
			Body = Read(Held)
		end
	end
	if Found ~= 1 then
		return nil
	end
	return Body
end

local function HeaderKey(Encoding: Encoding, Key: StoreKey): string
	return `{CopyKeyPrefix}{Summary.TagOf(Encoding, Key.Store, Key.Scope)}/{#Key.Key}:{Key.Key}`
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

local function DecodeIncarnation(Held: unknown): (boolean, ExtrasShapes.CopyIncarnation)
	if Held == nil then
		return true, nil
	elseif Held == NoIncarnationMark then
		return true, false
	elseif type(Held) ~= "table" then
		return false, nil
	end
	local Pair = Held :: Fields
	local Server = Summary.ReadPlain(Pair[1])
	local Counter = Summary.ReadPlain(Pair[2])
	if Server == nil or Counter == nil then
		return false, nil
	end
	return true, { Server = Server, Counter = Counter }
end

local function DecodeHeader(Raw: unknown): DecodedHeader
	if type(Raw) ~= "table" then
		return UnreadableHeader
	end
	local Item = Raw :: Fields
	local Version = Item[VersionKey]
	if type(Version) == "number" and Version > CopyVersion then
		return BehindHeader
	end
	local Q = Summary.ReadPlain(Item[QKey])
	local Level = Summary.ReadPlain(Item[LevelKey])
	local Floor = Summary.ReadPlain(Item[FloorKey])
	local Stamp = Summary.ReadHolderStamp(Item)
	local Body = DecodeBody(Item)
	local IsReadable, Incarnation = DecodeIncarnation(Item[IncarnationKey])
	if Version ~= CopyVersion or Q == nil or Level == nil or Floor == nil or Stamp == nil or Body == nil then
		return UnreadableHeader
	elseif not IsReadable then
		return UnreadableHeader
	end
	local Header: CopyHeader =
		{ Q = Q, Level = Level, Floor = Floor, Incarnation = Incarnation, HolderStamp = Stamp, Body = Body }
	return { Kind = "Header", Header = Header }
end

local function EncodePart(Part: CopyPart): Fields
	return {
		[QKey] = Part.Q,
		[LevelKey] = Part.Level,
		[PieceKey] = Part.Piece,
	}
end

local function DecodePart(Raw: unknown): CopyPart?
	if type(Raw) ~= "table" then
		return nil
	end
	local Item = Raw :: Fields
	local Q = Summary.ReadPlain(Item[QKey])
	local Level = Summary.ReadPlain(Item[LevelKey])
	local Piece = Item[PieceKey]
	if Q == nil or Level == nil or type(Piece) ~= "string" then
		return nil
	end
	return { Q = Q, Level = Level, Piece = Piece }
end

local function Fits(Header: CopyHeader): boolean
	return Json.Size(EncodeHeader(Header)) <= ItemRoom
end

local function PartFits(Q: number, Level: number, Piece: string): boolean
	return Json.Size(EncodePart({ Q = Q, Level = Level, Piece = Piece })) <= ItemRoom
end

local function LongestPiece(Text: string, From: number, Q: number, Level: number): number
	local Least = 0
	local Most = math.min(#Text - From + 1, ItemRoom)
	while Least < Most do
		local Middle = (Least + Most + 1) // 2
		if PartFits(Q, Level, string.sub(Text, From, From + Middle - 1)) then
			Least = Middle
		else
			Most = Middle - 1
		end
	end
	return Least
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

local function CopyKeys(Encoding: Encoding, Key: StoreKey): { string }
	local Header = HeaderKey(Encoding, Key)
	local Keys: { string } = { Header }
	for Slot = 0, CopySlots - 1 do
		for Index = 0, PartsMax - 1 do
			table.insert(Keys, PartKey(Header, Slot, Index))
		end
	end
	return Keys
end

local function RemoveCommands(Server: ServerState, Key: StoreKey): { MemoryRemoveCommand }
	local Encoding = Server.Encoding
	local Map = CopyMap(Encoding, HeaderKey(Encoding, Key))
	local Removals: { MemoryRemoveCommand } = {}
	for _, ItemKey in CopyKeys(Encoding, Key) do
		local Remove: MemoryRemoveCommand =
			{ Kind = "MemoryRemove", RequestId = Numbers.NewRequestId(Server), Map = Map, Key = ItemKey }
		table.insert(Removals, Remove)
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
