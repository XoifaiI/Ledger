--!strict
--!optimize 2

--[=[
	Incarnations: the incarnation an op carries (record sheet 6). A game key of an erasable store is read before
	its first op is sent; an op takes the key's id, "legacy" for a value with none, or "absent" with the fresh id
	every op first sent in its request shares. Other keys take "any". SharesFreshId tells which ops share one.

	Return type: A plain table of functions.
	Example usage:
		local Carried = Incarnations.IncarnationOf(State, Setup, Key)
--]=]

local Book = require("../Stored/Book")
local Cache = require("../Reading/Cache")
local KindSetup = require("../Judging/KindSetup")
local Names = require("../Encoding/Names")
local Numbers = require("./Numbers")
local Shapes = require("../Shapes")

type Identity = Book.Identity
type StoreKey = Names.StoreKey
type Incarnation = Shapes.Incarnation
type Op = Shapes.Op
type Setup = Shapes.Setup
type ServerState = Shapes.ServerState
type WriterState = Shapes.WriterState

local AnyIncarnation: Incarnation = table.freeze({ Kind = "Any" :: "Any" })
local LegacyIncarnation: Incarnation = table.freeze({ Kind = "Legacy" :: "Legacy" })

local NoIncarnationRead = "Incarnations: this call is never made. An op on an erasable key is sent only after the key"
	.. " was read."

local function IsUnseen(State: ServerState, Key: StoreKey): boolean
	if not KindSetup.IsErasableKey(Cache.StoreOf(State, Key).Setup, Key) then
		return false
	end
	local Entry = Cache.FindEntry(State, Key)
	return Entry == nil or Entry.Seen == nil
end

local function NeedsIncarnation(State: ServerState, Writer: WriterState): boolean
	if not IsUnseen(State, Writer.Key) then
		return false
	end
	for _, Op in Writer.Queue do
		if not Op.IsHeard and Op.Incarnation == nil then
			return true
		end
	end
	return false
end

local function TagOfValue(Identity: Identity?): Incarnation
	if Identity == nil then
		return LegacyIncarnation
	end
	return { Kind = "Known", Identity = Identity }
end

local function IncarnationOf(State: ServerState, Setup: Setup, Key: StoreKey): Incarnation
	if not KindSetup.IsErasableKey(Setup, Key) then
		return AnyIncarnation
	end
	local Entry = Cache.FindEntry(State, Key)
	if Entry == nil or Entry.Seen == nil then
		error(NoIncarnationRead)
	end
	local Seen = Entry.Seen
	if Seen.Kind == "Absent" then
		return { Kind = "Absent", Fresh = Numbers.DrawFreshId(State) }
	end
	if Seen.Kind == "Known" then
		return TagOfValue(Seen.Identity)
	end
	return LegacyIncarnation
end

local function IncarnationFor(
	State: ServerState,
	Setup: Setup,
	Key: StoreKey,
	Op: Op,
	FirstSent: Incarnation?
): Incarnation
	if Op.Incarnation ~= nil then
		return Op.Incarnation
	end
	if FirstSent ~= nil then
		return FirstSent
	end
	return IncarnationOf(State, Setup, Key)
end

local function IsSameIdentity(Identity: Identity, Other: Identity): boolean
	return Identity.Server == Other.Server and Identity.Counter == Other.Counter
end

local function SharesFreshId(Carried: Incarnation?, Other: Incarnation?): boolean
	if Carried == nil or Other == nil or Carried.Kind ~= "Absent" or Other.Kind ~= "Absent" then
		return false
	end
	return IsSameIdentity(Carried.Fresh, Other.Fresh)
end

return {
	IsUnseen = IsUnseen,
	NeedsIncarnation = NeedsIncarnation,
	TagOfValue = TagOfValue,
	IncarnationOf = IncarnationOf,
	IncarnationFor = IncarnationFor,
	SharesFreshId = SharesFreshId,
}
