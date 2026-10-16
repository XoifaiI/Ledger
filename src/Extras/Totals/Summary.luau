--!strict
--!optimize 2

--[=[
	Summary: the wire format of a summary item (extras sheet E5; Format 11, 12): its key (tagged with the store and
	scope), map, holder stamp, entry places, lapse test and MemoryStore transform. The transform merges entries by
	the larger q, cancels while another holder's until is ahead or the item is newer, and replaces a malformed one.

	Return type: A plain table of functions, the PairForm, PartForm, PairPlaces, PartPlaces and Flags, and the
	RawEntry and RawItem types.
	TagOf, ReadHolderStamp, ReadPlain and IsLapsed serve copy items.
	Example usage:
		local Item = Summary.TransformRaw(Carried, 16, ServerNumber, Summary.PairForm)(Stored, Clock) --> or nil
--]=]

local Check = require("../../Encoding/Check")
local Extras = require("../../Constants/Extras")
local ExtrasShapes = require("../Shapes")
local HashInputs = require("../../Encoding/HashInputs")
local Record = require("../../Constants/Record")

type Encoding = HashInputs.Encoding
type HolderStamp = ExtrasShapes.HolderStamp
type TotalDeclaration = ExtrasShapes.TotalDeclaration
type Fields = { [unknown]: unknown }
type HeldItem = { read HolderStamp: HolderStamp }
export type RawEntry = { number }
type StoredEntry = RawEntry | false
type EntryForm = { read Width: number, read Rules: { Check.Rule } }
export type RawItem =
	{ read Kind: "Item", read HolderStamp: HolderStamp, read Entries: { [number]: RawEntry } }
	| { read Kind: "Behind" }
	| { read Kind: "Unreadable" }

local PairsKey = "p"

local NoEntry: StoredEntry = false
local BehindItem = table.freeze({ Kind = "Behind" :: "Behind" })
local UnreadableItem = table.freeze({ Kind = "Unreadable" :: "Unreadable" })

local FlagClear = 0
local FlagSet = 1
local Flags = table.freeze({ Clear = FlagClear, Set = FlagSet })

local QPlace = 1
local PairPlaces = table.freeze({ Q = QPlace, Sum = 2 })
local PartPlaces = table.freeze({ Q = QPlace, Free = 2, Held = 3, Sold = 4, Sealed = 5, Closed = 6 })

local KeyKinds = Record.KeyKind

local TagWidth = 8
local TagBase = 2 ^ 6

local VersionKey = Record.ItemVersionKey
local HolderKey = Record.ItemHolderKey
local UntilKey = Record.ItemUntilKey
local AtKey = Record.ItemAtKey
local SummaryKeyPrefix = Record.SummaryKeyPrefix
local PartKeyPrefix = Record.PartKeyPrefix
local SummaryVersion = Record.SummaryVersion
local SummaryShardWidth = Record.SummaryShardWidth
local SummaryPartWidth = Record.SummaryPartWidth
local MapCount = Record.MapCount
local HolderSpan = Extras.HolderSpan
local LapseSlack = Extras.LapseSlack
local TakerJitter = Extras.TakerJitter
local ShardSumMost = Extras.ShardSumMost

local IsPlain = Check.Whole(0, ShardSumMost)
local IsHolder = Check.Whole(1, ShardSumMost)
local IsSum = Check.Whole(-ShardSumMost, ShardSumMost)
local IsFlag = Check.Whole(FlagClear, FlagSet)

local PairForm: EntryForm = { Width = SummaryShardWidth, Rules = { IsPlain, IsSum } }
local PartForm: EntryForm = { Width = SummaryPartWidth, Rules = { IsPlain, IsPlain, IsPlain, IsPlain, IsFlag, IsFlag } }

local function TagOf(Encoding: Encoding, Store: string, Scope: string): string
	local Left = HashInputs.ChoiceNumber(HashInputs.Hash(Encoding, HashInputs.ItemTagInput(Store, Scope)))
	local Text = ""
	for Place = TagWidth - 1, 0, -1 do
		local At = (Left // TagBase ^ Place) % TagBase
		Text ..= string.sub(Record.Alphabet, At + 1, At + 1)
	end
	return Text
end

local function SummaryKey(Encoding: Encoding, Store: string, Scope: string, Total: TotalDeclaration): string
	local Prefix = if Total.Keys == KeyKinds.Part then PartKeyPrefix else ""
	return `{SummaryKeyPrefix}{TagOf(Encoding, Store, Scope)}/{Prefix}{Total.Name}:{Total.KeyCount}`
end

local function MapOf(Encoding: Encoding, Prefix: string, ItemKey: string): string
	local Digest = HashInputs.Hash(Encoding, HashInputs.MapInput(ItemKey))
	return `{Prefix}{HashInputs.ChoiceNumber(Digest) % MapCount}`
end

local function EncodeEntries(Held: { [number]: RawEntry }, Count: number): { StoredEntry }
	local Entries: { StoredEntry } = {}
	for Index = 0, Count - 1 do
		local Found = Held[Index]
		if Found == nil then
			table.insert(Entries, NoEntry)
		else
			table.insert(Entries, Found)
		end
	end
	return Entries
end

local function EncodeSummary(HolderNumber: number, Until: number, At: number, Entries: { StoredEntry }): Fields
	return {
		[VersionKey] = SummaryVersion,
		[HolderKey] = HolderNumber,
		[UntilKey] = Until,
		[AtKey] = At,
		[PairsKey] = Entries,
	}
end

local function ReadWhole(Held: unknown, Rule: Check.Rule): number?
	if type(Held) ~= "number" or Rule(Held) ~= nil then
		return nil
	end
	return Held
end

local function ReadEntry(Raw: unknown, Form: EntryForm): RawEntry?
	if type(Raw) ~= "table" then
		return nil
	end
	local Held = Raw :: Fields
	if #Held ~= Form.Width then
		return nil
	end
	local Entry: RawEntry = {}
	for Place, Rule in Form.Rules do
		local Whole = ReadWhole(Held[Place], Rule)
		if Whole == nil then
			return nil
		end
		Entry[Place] = Whole
	end
	return Entry
end

local function ReadEntries(Raw: unknown, Count: number, Form: EntryForm): { [number]: RawEntry }?
	if type(Raw) ~= "table" then
		return nil
	end
	local Held = Raw :: Fields
	if #Held ~= Count then
		return nil
	end
	local Found: { [number]: RawEntry } = {}
	for Position = 1, Count do
		local Stored = Held[Position]
		if Stored ~= NoEntry then
			local Entry = ReadEntry(Stored, Form)
			if Entry == nil then
				return nil
			end
			Found[Position - 1] = Entry
		end
	end
	return Found
end

local function ReadHolderStamp(Item: Fields): HolderStamp?
	local HolderNumber = ReadWhole(Item[HolderKey], IsHolder)
	local Until = ReadWhole(Item[UntilKey], IsPlain)
	local At = ReadWhole(Item[AtKey], IsPlain)
	if HolderNumber == nil or Until == nil or At == nil then
		return nil
	end
	return { HolderNumber = HolderNumber, Until = Until, At = At }
end

local function ReadPlain(Held: unknown): number?
	return ReadWhole(Held, IsPlain)
end

local function ReadItem(Raw: unknown, Count: number, Form: EntryForm): RawItem
	if type(Raw) ~= "table" then
		return UnreadableItem
	end
	local Item = Raw :: Fields
	local Version = Item[VersionKey]
	if type(Version) == "number" and Version > SummaryVersion then
		return BehindItem
	end
	local Stamp = ReadHolderStamp(Item)
	local Entries = ReadEntries(Item[PairsKey], Count, Form)
	if Version ~= SummaryVersion or Stamp == nil or Entries == nil then
		return UnreadableItem
	end
	return { Kind = "Item", HolderStamp = Stamp, Entries = Entries }
end

local function MergeInto(
	Held: { [number]: RawEntry },
	Carried: { [number]: RawEntry },
	Count: number
): { [number]: RawEntry }
	local Kept: { [number]: RawEntry } = {}
	for Index = 0, Count - 1 do
		local Current = Held[Index]
		local Offered = Carried[Index]
		if Current == nil or (Offered ~= nil and Offered[QPlace] > Current[QPlace]) then
			Current = Offered
		end
		if Current ~= nil then
			Kept[Index] = Current
		end
	end
	return Kept
end

local function TransformRaw(
	Carried: { [number]: RawEntry },
	Count: number,
	ServerNumber: number,
	Form: EntryForm
): (Current: unknown, Clock: number) -> unknown?
	return function(Current: unknown, Clock: number): unknown?
		local Read = ReadItem(Current, Count, Form)
		if Read.Kind == "Behind" then
			return nil
		end
		local Held: { [number]: RawEntry } = {}
		if Read.Kind == "Item" then
			if Read.HolderStamp.HolderNumber ~= ServerNumber and Read.HolderStamp.Until > Clock then
				return nil
			end
			Held = Read.Entries
		end
		local Entries = EncodeEntries(MergeInto(Held, Carried, Count), Count)
		return EncodeSummary(ServerNumber, Clock + HolderSpan, Clock, Entries)
	end
end

local function IsLapsed(Item: HeldItem, Clock: number, Fraction: number): boolean
	return Clock > Item.HolderStamp.Until + LapseSlack + Fraction * TakerJitter
end

return {
	TagOf = TagOf,
	SummaryKey = SummaryKey,
	MapOf = MapOf,
	ReadHolderStamp = ReadHolderStamp,
	ReadPlain = ReadPlain,
	PairForm = PairForm,
	PartForm = PartForm,
	PairPlaces = PairPlaces,
	PartPlaces = PartPlaces,
	Flags = Flags,
	ReadItem = ReadItem,
	TransformRaw = TransformRaw,
	IsLapsed = IsLapsed,
}
