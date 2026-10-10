--!strict
--!optimize 2

--[=[
	Shown: a server's shown table (record sheet 14, Format.md 4): per key the largest write count shown of one
	incarnation, with its id, and one bit per hash of a key that left. A read of another incarnation starts the count
	again. A copy carries its key's id; one from an older build carries none, and on an erasable store any read
	replaces it. A session's key never leaves.

	A full table lets its least recently shown key go, in the order Order keeps, once the new key is in (Recency says
	why). A lap passes over an open session's key and the key being added, counting each as shown then, so it may find
	none.

	Return type: A plain table of functions.
	Example usage:
		Shown.Show(State, Key, WriteCount, Identity, Clock, OpenKeys)
--]=]

local Book = require("../Stored/Book")
local Cache = require("./Cache")
local HashInputs = require("../Encoding/HashInputs")
local KindSetup = require("../Judging/KindSetup")
local Names = require("../Encoding/Names")
local Recency = require("../Recency")
local Shapes = require("../Shapes")

type Identity = Book.Identity
type StoreKey = Names.StoreKey
type ServerState = Shapes.ServerState
type ShownIncarnation = Shapes.ShownIncarnation
type ShownTable = Shapes.ShownTable

local OneBit = 1

local NoIncarnation: ShownIncarnation = table.freeze({ Kind = "None" :: "None" })
local UnknownIncarnation: ShownIncarnation = table.freeze({ Kind = "Unknown" :: "Unknown" })

local function BitOf(State: ServerState, Key: StoreKey): number
	local Digest = HashInputs.Hash(State.Encoding, HashInputs.ShownInput(Key.Store, Key.Scope, Key.Key))
	return HashInputs.ChoiceNumber(Digest) % Cache.ServerLimits(State).ShownBitCount
end

local function LargestOf(State: ServerState, Key: StoreKey): number?
	return State.Shown.Counts[Names.KeyText(Key)]
end

local function LastShownAt(State: ServerState, Key: StoreKey): number?
	return State.Shown.LastShown[Names.KeyText(Key)]
end

local function IsBitSet(Shown: ShownTable, Bit: number): boolean
	return buffer.readbits(Shown.Bits, Bit, OneBit) == 1
end

local function IncarnationOf(Identity: Identity?): ShownIncarnation
	if Identity == nil then
		return NoIncarnation
	end
	return { Kind = "Known", Identity = Identity }
end

local function IsSameIncarnation(Shown: ShownTable, Text: string, Identity: Identity?): boolean
	local Held = Shown.Incarnations[Text]
	if Held == nil then
		return true
	end
	if Held.Kind == "Unknown" then
		return false
	end
	if Held.Kind == "None" or Identity == nil then
		return Held.Kind == "None" and Identity == nil
	end
	return Held.Identity.Server == Identity.Server and Held.Identity.Counter == Identity.Counter
end

local function Forget(State: ServerState, Text: string)
	local Shown = State.Shown
	buffer.writebits(Shown.Bits, BitOf(State, Shown.Keys[Text]), OneBit, 1)
	Recency.Remove(Shown.Order, Text)
	Shown.Keys[Text] = nil
	Shown.Counts[Text] = nil
	Shown.Incarnations[Text] = nil
	Shown.LastShown[Text] = nil
end

local function Evict(State: ServerState, OpenKeys: { read [string]: unknown }, Adding: string): boolean
	local Order = State.Shown.Order
	for _ = 1, Order.Count do
		local Least = Recency.Oldest(Order)
		if Least == nil then
			return false
		end
		if OpenKeys[Least] == nil and Least ~= Adding then
			Forget(State, Least)
			return true
		end
		Recency.Use(Order, Least)
	end
	return false
end

local function MakeRoom(State: ServerState, OpenKeys: { read [string]: unknown }, Adding: string)
	local Order = State.Shown.Order
	while Order.Count > Cache.ServerLimits(State).ShownKeysMax do
		if not Evict(State, OpenKeys, Adding) then
			return
		end
	end
end

local function AddKey(State: ServerState, Key: StoreKey, Text: string): boolean
	local Shown = State.Shown
	local IsNew = Shown.Counts[Text] == nil
	if IsNew then
		Shown.Keys[Text] = Key
	end
	Recency.Use(Shown.Order, Text)
	return IsNew
end

local function Show(
	State: ServerState,
	Key: StoreKey,
	WriteCount: number,
	Identity: Identity?,
	Clock: number,
	OpenKeys: { read [string]: unknown }
)
	local Shown = State.Shown
	local Text = Names.KeyText(Key)
	local IsNew = AddKey(State, Key, Text)
	local Largest = Shown.Counts[Text]
	if Largest == nil or WriteCount > Largest or not IsSameIncarnation(Shown, Text, Identity) then
		Shown.Counts[Text] = WriteCount
	end
	Shown.Incarnations[Text] = IncarnationOf(Identity)
	Shown.LastShown[Text] = Clock
	if IsNew then
		MakeRoom(State, OpenKeys, Text)
	end
end

local function ShowCopy(
	State: ServerState,
	Key: StoreKey,
	WriteCount: number,
	Carried: (Identity | false)?,
	Clock: number,
	OpenKeys: { read [string]: unknown }
)
	local Shown = State.Shown
	local Text = Names.KeyText(Key)
	local IsNew = AddKey(State, Key, Text)
	local Largest = Shown.Counts[Text]
	if Largest == nil or WriteCount > Largest then
		Shown.Counts[Text] = WriteCount
		if Carried ~= nil then
			Shown.Incarnations[Text] = IncarnationOf(if Carried == false then nil else Carried)
		elseif KindSetup.IsErasableKey(Cache.StoreOf(State, Key).Setup, Key) then
			Shown.Incarnations[Text] = UnknownIncarnation
		end
	end
	Shown.LastShown[Text] = Clock
	if IsNew then
		MakeRoom(State, OpenKeys, Text)
	end
end

local function IsAbsentWithBit(State: ServerState, Key: StoreKey): boolean
	local Shown = State.Shown
	if Shown.Counts[Names.KeyText(Key)] ~= nil then
		return false
	end
	return IsBitSet(Shown, BitOf(State, Key))
end

local function IsShown(State: ServerState, Key: StoreKey, WriteCount: number, Identity: Identity?): boolean
	local Text = Names.KeyText(Key)
	local Largest = State.Shown.Counts[Text]
	if Largest == nil then
		return not IsAbsentWithBit(State, Key)
	end
	if not IsSameIncarnation(State.Shown, Text, Identity) then
		return true
	end
	return WriteCount >= Largest
end

local function IsNewerThanShown(State: ServerState, Key: StoreKey, WriteCount: number, Identity: Identity?): boolean
	local Text = Names.KeyText(Key)
	local Largest = State.Shown.Counts[Text]
	if Largest == nil then
		return false
	end
	if not IsSameIncarnation(State.Shown, Text, Identity) then
		return true
	end
	return WriteCount > Largest
end

local function IsCopyShown(State: ServerState, Key: StoreKey, WriteCount: number): boolean
	local Largest = LargestOf(State, Key)
	if Largest ~= nil then
		return WriteCount >= Largest
	end
	return not IsAbsentWithBit(State, Key)
end

local function IsCopyAboveShown(State: ServerState, Key: StoreKey, WriteCount: number): boolean
	local Largest = LargestOf(State, Key)
	return Largest == nil or WriteCount > Largest
end

return {
	BitOf = BitOf,
	LargestOf = LargestOf,
	LastShownAt = LastShownAt,
	Show = Show,
	ShowCopy = ShowCopy,
	IsAbsentWithBit = IsAbsentWithBit,
	IsShown = IsShown,
	IsNewerThanShown = IsNewerThanShown,
	IsCopyShown = IsCopyShown,
	IsCopyAboveShown = IsCopyAboveShown,
}
