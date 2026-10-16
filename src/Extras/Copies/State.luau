--!strict
--!optimize 2

--[=[
	State: what a server keeps of the copies it holds and follows (sheet E8, E9). A CopyHolder is one key's
	refresh, with its lease and UsedAt, when a local tick last reached it; Copies/Refresh keeps its times due. A
	Follower ticks for observers or a Peek (PeekWork); NextAt is nil while a tick is out. A CopyPlan is a push; a
	CopyRead an ended read.

	Return type: A plain table with NewCopyHolder, NoteUsed, NewFollower and CopyOpenCount, and the CopyLease,
	CopyHolder, Serving, Follower, PeekWork, CopyRead, CopyPlan, PartSet, HeaderUpdate, AdviceGet, ItemRemove,
	HeaderGet, PartGet and Decode types.
	Example usage:
		local Holder = CopyState.NewCopyHolder(Key, Names.KeyText(Key), Clock)
--]=]

local Extras = require("../../Constants/Extras")
local ExtrasShapes = require("../Shapes")
local Names = require("../../Encoding/Names")
local Reads = require("../../Reading/Reads")

type StoreKey = Names.StoreKey
type CopyBody = ExtrasShapes.CopyBody
type CopyHeader = ExtrasShapes.CopyHeader
type CopyPart = ExtrasShapes.CopyPart
type PeekWithinCall = ExtrasShapes.PeekWithinCall

export type CopyLease = {
	read Q: number,
	read PushedAt: number,
	read Until: number,
}

export type CopyHolder = {
	read Key: StoreKey,
	read Text: string,
	IsRefreshing: boolean,
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

export type PartSet = { read Kind: "PartSet", read Holder: CopyHolder, read Plan: CopyPlan, read Index: number }

export type HeaderUpdate = {
	read Kind: "HeaderUpdate",
	read Holder: CopyHolder,
	read Header: CopyHeader,
	read PushedAt: number,
}

export type AdviceGet = { read Kind: "AdviceGet", read Key: StoreKey }

export type ItemRemove = { read Kind: "ItemRemove" }

export type HeaderGet = { read Kind: "HeaderGet", read Follower: Follower }

export type PartGet = {
	read Kind: "PartGet",
	read Follower: Follower,
	read Header: CopyHeader,
	read Count: number,
	read Got: { CopyPart },
}

export type Decode = { read Kind: "Decode", read Follower: Follower, read Header: CopyHeader }

local function NewCopyHolder(Key: StoreKey, Text: string, Clock: number): CopyHolder
	return { Key = Key, Text = Text, IsRefreshing = false, Lease = nil, NextAt = nil, UsedAt = Clock }
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
