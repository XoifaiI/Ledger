--!strict
--!optimize 2

--[=[
	Replicas: how a copy spreads over replicas so many followers share its reads (extras sheet E7 to E9): the merge
	of a replica's header, a server's count, home replica and cold key (Spread), and a replica that looks
	unrefreshed. Replica 0 alone holds the lease and is written last, so its Written never claims more replicas
	than were written at its q. A merge keeps the writer's stamp, which on replica 0 has passed the lease check
	(Copies/Push). The count only grows while a copy lives: a holder that shrinks it can strand a replica its
	followers still read (CopyRep.tla). A server keeps the count it last read in the key's cache entry, as the
	model keeps it per server (Copy.tla nf), so a Peek's new follower starts from it. A replica no push wrote for
	RepushAge plus LapseSlack looks unrefreshed.

	Return type: A plain table of functions.
	Example usage:
		local Merged = Replicas.Merge(Held, Carried, false)
		local Replica = Replicas.HomeOf(Server, Key)
--]=]

local Cache = require("../../../Record/Reading/Cache")
local Extras = require("../../../Record/Constants/Extras")
local ExtrasShapes = require("../Shapes")
local Items = require("./Items")
local Names = require("../../../Record/Encoding/Names")
local Numbers = require("../../../Record/Writing/Numbers")
local Shapes = require("../../../Machine/Shapes")
local Spread = require("../Spread")

type CopyHeader = ExtrasShapes.CopyHeader
type StoreKey = Names.StoreKey
type ServerState = Shapes.ServerState

local RepushAge = Extras.RepushAge
local LapseSlack = Extras.LapseSlack

local function WrittenAfter(Held: CopyHeader, Carried: CopyHeader): number
	if Carried.Q > Held.Q then
		return Carried.Written
	end
	if Carried.Q == Held.Q then
		return math.max(Held.Written, Carried.Written)
	end
	return Held.Written
end

local function Merge(Held: CopyHeader, Carried: CopyHeader, TakesCarried: boolean): CopyHeader
	local IsCarriedState = Carried.Q > Held.Q or (Carried.Q == Held.Q and TakesCarried)
	local Shown = if IsCarriedState then Carried else Held
	return {
		Q = Shown.Q,
		Level = Shown.Level,
		Floor = Shown.Floor,
		Incarnation = Shown.Incarnation,
		HolderStamp = Carried.HolderStamp,
		Body = Shown.Body,
		Replicas = math.max(Held.Replicas, Carried.Replicas),
		Written = WrittenAfter(Held, Carried),
	}
end

local function CountOf(Server: ServerState, Key: StoreKey): number
	local Entry = Cache.FindEntry(Server, Key)
	local Count = if Entry ~= nil then Entry.CopyReplicas else nil
	return Count or 1
end

local function NoteCount(Server: ServerState, Key: StoreKey, Count: number)
	Numbers.EntryFor(Server, Key).CopyReplicas = Count
end

local function SlotOf(Server: ServerState, Key: StoreKey): number
	return Spread.SlotOf(Server.Encoding, Items.HeaderKey(Server.Encoding, Key, 0), Server.ServerNumber)
end

local function HomeOf(Server: ServerState, Key: StoreKey): number
	local Count = CountOf(Server, Key)
	if Count == 1 then
		return 0
	end
	return Spread.HomeOf(SlotOf(Server, Key), Count)
end

local function ColdKeyOf(Server: ServerState, Key: StoreKey): string
	return Spread.ColdKey(Items.HeaderKey(Server.Encoding, Key, 0), SlotOf(Server, Key))
end

local function IsUnrefreshed(Header: CopyHeader, Clock: number): boolean
	return Clock > Header.HolderStamp.At + RepushAge + LapseSlack
end

return {
	Merge = Merge,
	CountOf = CountOf,
	NoteCount = NoteCount,
	HomeOf = HomeOf,
	ColdKeyOf = ColdKeyOf,
	IsUnrefreshed = IsUnrefreshed,
}
