--!strict
--!optimize 2

--[=[
	SentNames: the server's table of the game names it sent (record sheet 4, Charter item 33): for each of
	the last SentNamesKept names, the whole SHA-256 digest of the terms it was first sent with.

	SentOrder keeps the names in the order they were last sent (Recency), sized by the server's Limits (the first
	store's): a new name in a full table lets the least recently sent go, once it is in (Recency says why). The caller
	builds the warning.

	Return type: A plain table of functions, and the Remembered table and type.
	Example usage:
		local Result = SentNames.Remember(State, SentNames.OneKeyEntry(Key, "Buy7"), Digest)
--]=]

local Cache = require("../Reading/Cache")
local Format = require("../Encoding/Format")
local Names = require("../Encoding/Names")
local Recency = require("../Recency")
local Shapes = require("../Shapes")

type StoreKey = Names.StoreKey
type ServerState = Shapes.ServerState

local Remembered = {
	New = "New" :: "New",
	SameTerms = "SameTerms" :: "SameTerms",
	OtherTerms = "OtherTerms" :: "OtherTerms",
}

export type Remembered = keyof<typeof(Remembered)>

local EntryStartBytes = 64
local TxTag = "."

local function OneKeyEntry(Key: StoreKey, Name: string): string
	local Out = Format.NewWriter(EntryStartBytes)
	Names.WriteKey(Out, { Kind = "Full", Store = Key.Store, Scope = Key.Scope, Key = Key.Key })
	Names.WriteStored(Out, Name)
	return Format.ToString(Out)
end

local function TxEntry(Name: string): string
	local Out = Format.NewWriter(EntryStartBytes)
	Format.WriteRaw(Out, TxTag)
	Names.WriteStored(Out, Name)
	return Format.ToString(Out)
end

local function ForgetOldest(State: ServerState)
	local Oldest = Recency.Oldest(State.SentOrder)
	if Oldest ~= nil then
		Recency.Remove(State.SentOrder, Oldest)
		State.SentNames[Oldest] = nil
	end
end

local function Remember(State: ServerState, Entry: string, Digest: string): Remembered
	local Order = State.SentOrder
	local Earlier = State.SentNames[Entry]
	if Earlier == nil then
		State.SentNames[Entry] = Digest
		Recency.Use(Order, Entry)
		if Order.Count > Cache.ServerLimits(State).SentNamesKept then
			ForgetOldest(State)
		end
		return Remembered.New
	end
	Recency.Use(Order, Entry)
	if Earlier == Digest then
		return Remembered.SameTerms
	end
	return Remembered.OtherTerms
end

return {
	OneKeyEntry = OneKeyEntry,
	TxEntry = TxEntry,
	Remember = Remember,
	Remembered = Remembered,
}
