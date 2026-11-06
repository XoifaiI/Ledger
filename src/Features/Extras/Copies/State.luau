--!strict
--!optimize 2

--[=[
	State: what a server keeps of the copies it holds and follows (sheet E8, E9). A CopyHolder is one key's
	refresh, with its Count of replicas, its lease and UsedAt, when a local tick last reached it; Copies/Refresh
	keeps its times due. Count lives as long as the holder, so a dropped lease keeps it. A lease keeps replica 0's
	merged Replicas and Written. A Follower ticks for observers or a Peek (PeekWork); NextAt
	is nil while a tick is out, and ReadsZero sends its next tick to replica 0. A CopyPlan is the state a push
	writes, and a CopyPush one push: Left counts its replicas other than 0 still being written, and IsWhole says
	none of them failed. A CopyRead is an ended read. Every item request names its replica.

	Return type: A plain table with NewCopyHolder, NoteUsed, NewFollower and CopyOpenCount, and the CopyLease,
	CopyHolder, Serving, Follower, PeekWork, CopyRead, CopyPlan, CopyPush, PartSet, HeaderUpdate, AdviceGet,
	ItemRemove, HeaderGet, PartGet, Decode, ColdRead and TickCold types.
	Example usage:
		local Holder = CopyState.NewCopyHolder(Key, Names.KeyText(Key), Clock)
--]=]

local Extras = require("../../../Record/Constants/Extras")
local ExtrasShapes = require("../Shapes")
local Names = require("../../../Record/Encoding/Names")
local Reads = require("../../../Record/Reading/Reads")

type StoreKey = Names.StoreKey
type CopyBody = ExtrasShapes.CopyBody
type CopyHeader = ExtrasShapes.CopyHeader
type CopyPart = ExtrasShapes.CopyPart
type PeekWithinCall = ExtrasShapes.PeekWithinCall

export type CopyLease = {
	read Q: number,
	read PushedAt: number,
	read Until: number,
	read Replicas: number,
	read Written: number,
}

export type CopyHolder = {
	read Key: StoreKey,
	read Text: string,
	IsRefreshing: boolean,
	Count: number,
	Lease: CopyLease?,
	NextAt: number?,
	UsedAt: number,
}

export type Serving = { read Kind: "Subscribers" } | { read Kind: "Call", read CallId: number }

export type Follower = {
	read Key: StoreKey,
	read Serves: Serving,
	NextAt: number?,
	TickEvery: number,
	Misses: number,
	EmittedQ: number?,
	KeyCallId: number?,
	FollowEvery: number,
	IsKeyThrottled: boolean,
	KeyFraction: number,
	ReadsZero: boolean,
}

export type PeekWork = {
	read Call: PeekWithinCall,
	read Deadline: number,
	read Follower: Follower,
}

export type CopyRead = Reads.Opened | Reads.Handed

export type CopyPlan = {
	read Q: number,
	read Level: number,
	read Floor: number,
	read Incarnation: ExtrasShapes.CopyIncarnation,
	read Body: CopyBody,
	read Pieces: { string },
}

export type CopyPush = {
	read Plan: CopyPlan,
	read Count: number,
	Left: number,
	IsWhole: boolean,
}

export type PartSet = {
	read Kind: "PartSet",
	read Holder: CopyHolder,
	read Push: CopyPush,
	read Replica: number,
	read Index: number,
}

export type HeaderUpdate = {
	read Kind: "HeaderUpdate",
	read Holder: CopyHolder,
	read Header: CopyHeader,
	read PushedAt: number,
	read Replica: number,
	read Push: CopyPush?,
}

export type AdviceGet = { read Kind: "AdviceGet", read Key: StoreKey }

export type ItemRemove = { read Kind: "ItemRemove" }

export type HeaderGet = { read Kind: "HeaderGet", read Follower: Follower, read Replica: number }

export type PartGet = {
	read Kind: "PartGet",
	read Follower: Follower,
	read Header: CopyHeader,
	read Count: number,
	read Got: { CopyPart },
	read Replica: number,
}

export type Decode = {
	read Kind: "Decode",
	read Follower: Follower,
	read Header: CopyHeader,
	read Replica: number,
}

export type ColdRead = { read Kind: "ColdRead", read Holder: CopyHolder }

export type TickCold = { read Kind: "TickCold", read Follower: Follower }

local function NewCopyHolder(Key: StoreKey, Text: string, Clock: number): CopyHolder
	return { Key = Key, Text = Text, IsRefreshing = false, Count = 1, Lease = nil, NextAt = nil, UsedAt = Clock }
end

local function NoteUsed(Holders: { [string]: CopyHolder }, Key: StoreKey, Clock: number)
	local Holder = Holders[Names.KeyText(Key)]
	if Holder ~= nil then
		Holder.UsedAt = Clock
	end
end

local function NewFollower(Key: StoreKey, Serves: Serving): Follower
	return {
		Key = Key,
		Serves = Serves,
		NextAt = nil,
		TickEvery = Extras.TickFirst,
		Misses = 0,
		EmittedQ = nil,
		KeyCallId = nil,
		FollowEvery = Extras.IntervalFirst,
		IsKeyThrottled = false,
		KeyFraction = 0,
		ReadsZero = false,
	}
end

local function CopyOpenCount(Holders: { [string]: CopyHolder }): number
	local Count = 0
	for _, Holder in Holders do
		if Holder.IsRefreshing then
			Count += 1
		end
	end
	return Count
end

return {
	NewCopyHolder = NewCopyHolder,
	NoteUsed = NoteUsed,
	NewFollower = NewFollower,
	CopyOpenCount = CopyOpenCount,
}
