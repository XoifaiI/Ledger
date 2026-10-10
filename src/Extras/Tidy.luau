--!strict
--!optimize 2

--[=[
	Tidy: when a shard or part is tidied (extras sheet E6). A read showing an item PruneAge old makes a tidy due,
	at most once per key per PruneAge. Owe has the key's writer send a request with no op, making the writer if
	new, and stops at the close. It lands only if the age step drops something.

	Return type: A plain table with IsDue and Owe.
	Example usage:
		if Tidy.IsDue(Kept, Entry, Clock) then Tidy.Owe(State, Key, Clock, Fraction) end
--]=]

local Cache = require("../Reading/Cache")
local Composed = require("../Composed")
local Durable = require("../Writing/Durable")
local Extras = require("../Constants/Extras")
local Names = require("../Encoding/Names")
local Numbers = require("../Writing/Numbers")
local Record = require("../Constants/Record")
local Rooms = require("../Stored/Rooms")
local Shapes = require("../Shapes")
local Value = require("../Stored/Value")
local Writers = require("../Writing/Writer")

type StoreKey = Names.StoreKey
type CacheEntry = Shapes.CacheEntry
type Kept = Value.Kept
type State = Composed.State

local ShardKind = Record.KeyKind.Shard

local PruneAge = Extras.PruneAge

local function IsTidiedRecently(Entry: CacheEntry, Clock: number): boolean
	local TidiedAt = Entry.TidiedAt
	return TidiedAt ~= nil and Clock < TidiedAt + PruneAge
end

local function IsDue(Kept: Kept, Entry: CacheEntry, Clock: number): boolean
	if IsTidiedRecently(Entry, Clock) then
		return false
	end
	for _, Item in Kept.Book.Timed do
		if Clock - Rooms.ItemStamp(Item) >= PruneAge then
			return true
		end
	end
	return false
end

local function Owe(State: State, Key: StoreKey, Clock: number, Fraction: number)
	if State.Sessions.Shutdown ~= nil then
		return
	end
	local Server = State.Server
	local Entry = Numbers.EntryFor(Server, Key)
	if IsTidiedRecently(Entry, Clock) or not Writers.CanStartWriter(Server, Key) then
		return
	end
	local Setup = Cache.StoreOf(Server, Key).Setup
	local Writer = Durable.EnsurePacedWriter(Server, Key, Setup, Cache.KindOfKey(Key) == ShardKind, Fraction, Clock)
	Writer.TidyOwed = true
	Entry.TidiedAt = Clock
	Composed.NoteSendable(State, Key)
end

return {
	IsDue = IsDue,
	Owe = Owe,
}
