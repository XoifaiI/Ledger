--!strict
--!optimize 2

--[=[
	Shapes: what totals and copies add to calls, items and pairs. A total sums KeyCount keys: shards, or a
	quantity's parts when Keys is Part. A Pair is a shard's write count and sum as last known. A Breaker counts
	failed summary requests. A HolderStamp is an item's hd, un and at. A CopyHeader heads a copy.

	Return type: An empty table. The types are TotalDeclaration, Pair, Breaker, TotalRef, BumpCall, TotalCall,
	FollowCall, UnfollowCall, StaleCall, PeekWithinCall, ExtrasCall, SummaryItem, HolderStamp, CopyBody, CopyHeader and
	CopyPart.
	Example usage:
		local ExtrasShapes = require("./Extras/Shapes")
		type Pair = ExtrasShapes.Pair
--]=]

local Book = require("../Stored/Book")
local Names = require("../Encoding/Names")

type GivenName = Names.GivenName
type StoreKey = Names.StoreKey

export type TotalDeclaration = {
	read Name: string,
	read KeyCount: number,
	read Keys: "Shard" | "Part",
}

export type Pair = {
	read Q: number,
	read Sum: number,
}

export type Breaker = {
	Misses: number,
	OpenUntil: number?,
}

export type TotalRef = {
	read Store: string,
	read Scope: string,
	read Total: TotalDeclaration,
}

export type BumpCall = {
	read Kind: "Call",
	read Method: "Bump",
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Total: TotalDeclaration,
	read Amount: number,
	read Name: GivenName?,
	read Fraction: number,
}

export type TotalCall = {
	read Kind: "Call",
	read Method: "Total",
	read CallId: number,
	read Store: string,
	read Scope: string,
	read Total: TotalDeclaration,
	read MaxAge: number,
	read Fraction: number,
}

export type FollowCall = {
	read Kind: "Call",
	read Method: "Follow",
	read CallId: number,
	read Key: StoreKey,
}

export type UnfollowCall = {
	read Kind: "Call",
	read Method: "Unfollow",
	read CallId: number,
	read Key: StoreKey,
}

export type StaleCall = {
	read Kind: "Call",
	read Method: "Stale",
	read CallId: number,
}

export type PeekWithinCall = {
	read Kind: "Call",
	read Method: "PeekWithin",
	read CallId: number,
	read Key: StoreKey,
	read MaxAge: number,
}

export type ExtrasCall = BumpCall | TotalCall | FollowCall | UnfollowCall | StaleCall | PeekWithinCall

export type SummaryItem<Entry> = {
	read HolderStamp: HolderStamp,
	read Entries: { [number]: Entry },
}

export type HolderStamp = {
	read HolderNumber: number,
	read Until: number,
	read At: number,
}

export type CopyBody =
	{ read Kind: "State", read State: { [unknown]: unknown } }
	| { read Kind: "Parts", read Count: number }
	| { read Kind: "Big" }

export type CopyIncarnation = (Book.Identity | false)?

export type CopyHeader = {
	read Q: number,
	read Level: number,
	read Floor: number,
	read Incarnation: CopyIncarnation,
	read HolderStamp: HolderStamp,
	read Body: CopyBody,
}

export type CopyPart = {
	read Q: number,
	read Level: number,
	read Piece: string,
}

return {}
