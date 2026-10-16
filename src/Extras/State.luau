--!strict
--!optimize 2

--[=[
	State: a server's extras state, in Composed.State.Extras (extras sheet E4, E5): a TotalView per total, a
	SummaryHolder per summary refresh (UsedAt: its last local Total call), a TotalWork per Total call, the
	CopyHolders and Followers (Copies/State), the open Peeks, whether Stale is watched, and CopyReads, the ended copy
	reads. A Purpose finds a request's owner. CopyTimes and SummaryTimes hold the holders' due times (DueTimes): a
	refresh at NextAt, and an expiry check at UsedAt plus the age that ends it, which HolderOf files first.

	Return type: A plain table of functions, and the TotalView, SummaryHolder, OutRead, TotalWork, ReadRound,
	TotalKeyRead, SummaryGet, SummaryUpdate, Purpose, HolderTimes and ExtrasState types.
	Example usage:
		local State = ExtrasState.NewState()
		local View = ExtrasState.ViewOf(State, "Shop", "global", { Name = "coins", KeyCount = 16, Keys = "Shard" })
--]=]

local CopyState = require("./Copies/State")
local DueTimes = require("../DueTimes")
local Extras = require("../Constants/Extras")
local ExtrasShapes = require("./Shapes")
local GetOrMake = require("../GetOrMake").GetOrMake
local Names = require("../Encoding/Names")
local Numbers = require("../Writing/Numbers")
local Shapes = require("../Shapes")

type Breaker = ExtrasShapes.Breaker
type AdviceGet = CopyState.AdviceGet
type CopyHolder = CopyState.CopyHolder
type CopyRead = CopyState.CopyRead
type Decode = CopyState.Decode
type Follower = CopyState.Follower
type HeaderGet = CopyState.HeaderGet
type HeaderUpdate = CopyState.HeaderUpdate
type ItemRemove = CopyState.ItemRemove
type PartGet = CopyState.PartGet
type PartSet = CopyState.PartSet
type PeekWork = CopyState.PeekWork
type Pair = ExtrasShapes.Pair
type TotalCall = ExtrasShapes.TotalCall
type TotalDeclaration = ExtrasShapes.TotalDeclaration
type TotalRef = ExtrasShapes.TotalRef
type ServerState = Shapes.ServerState
type StoreKey = Names.StoreKey
type DueTimes<Item> = DueTimes.DueTimes<Item>

export type OutRead = {
	read RequestId: number,
	read SentAt: number,
}

export type TotalView = {
	Pairs: { [number]: Pair },
	SeenAt: number?,
	ReadAt: { [number]: number },
	ReadOut: { [number]: OutRead },
	Interval: number,
	Breaker: Breaker,
	Holder: SummaryHolder?,
}

type ViewsOfName = { [number]: TotalView }

type ViewsOfScope = { [string]: ViewsOfName }

type ViewsOfStore = { [string]: ViewsOfScope }

export type SummaryHolder = {
	read Store: string,
	read Scope: string,
	read Total: TotalDeclaration,
	Out: number,
	NextAt: number?,
	UsedAt: number,
}

export type TotalWork = {
	read Call: TotalCall,
	read Deadline: number,
	Waits: { [number]: boolean },
	IsTakerOwed: boolean,
	Tidies: { StoreKey },
}

export type ReadRound = {
	Pending: number,
	IsThrottled: boolean,
	IsGood: boolean,
}

export type TotalKeyRead = {
	read Kind: "TotalKeyRead",
	read Ref: TotalRef,
	read Index: number,
	read Fraction: number,
	read Round: ReadRound,
}

export type SummaryGet = { read Kind: "SummaryGet", read Ref: TotalRef }

export type SummaryUpdate = { read Kind: "SummaryUpdate", read Holder: SummaryHolder }

export type Purpose =
	{ read Kind: "RefreshRead", read Holder: SummaryHolder, read Index: number }
	| SummaryUpdate
	| TotalKeyRead
	| SummaryGet
	| PartSet
	| HeaderUpdate
	| AdviceGet
	| ItemRemove
	| HeaderGet
	| PartGet
	| Decode

export type HolderTimes<Item> = {
	Refreshes: DueTimes<Item>,
	Expiries: DueTimes<Item>,
}

export type ExtrasState = {
	Views: { [string]: ViewsOfStore },
	Holders: { SummaryHolder },
	Calls: { [number]: TotalWork },
	Purposes: { [number]: Purpose },
	CopyHolders: { [string]: CopyHolder },
	Followers: { [string]: Follower },
	Peeks: { [number]: PeekWork },
	IsStaleWatched: boolean,
	CopyReads: { CopyRead },
	CopyTimes: HolderTimes<string>,
	SummaryTimes: HolderTimes<SummaryHolder>,
}

local function NewView(): TotalView
	return {
		Pairs = {},
		SeenAt = nil,
		ReadAt = {},
		ReadOut = {},
		Interval = Extras.IntervalFirst,
		Breaker = { Misses = 0, OpenUntil = nil },
		Holder = nil,
	}
end

local function NewState(): ExtrasState
	return {
		Views = {},
		Holders = {},
		Calls = {},
		Purposes = {},
		CopyHolders = {},
		Followers = {},
		Peeks = {},
		IsStaleWatched = false,
		CopyReads = {},
		CopyTimes = { Refreshes = {}, Expiries = {} },
		SummaryTimes = { Refreshes = {}, Expiries = {} },
	}
end

local function ViewOf(State: ExtrasState, Store: string, Scope: string, Total: TotalDeclaration): TotalView
	local OfStore = GetOrMake(State.Views, Store, function(): ViewsOfStore
		return {}
	end)
	local OfScope = GetOrMake(OfStore, Scope, function(): ViewsOfScope
		return {}
	end)
	local OfName = GetOrMake(OfScope, Total.Name, function(): ViewsOfName
		return {}
	end)
	return GetOrMake(OfName, Total.KeyCount, NewView)
end

local function HolderOf(
	State: ExtrasState,
	Store: string,
	Scope: string,
	Total: TotalDeclaration,
	Clock: number
): SummaryHolder
	local View = ViewOf(State, Store, Scope, Total)
	local Held = View.Holder
	if Held ~= nil then
		return Held
	end
	local Holder: SummaryHolder = { Store = Store, Scope = Scope, Total = Total, Out = 0, NextAt = nil, UsedAt = Clock }
	View.Holder = Holder
	table.insert(State.Holders, Holder)
	DueTimes.Add(State.SummaryTimes.Expiries, Holder, Clock + Extras.SummaryExpiry)
	return Holder
end

local function IsHeld(State: ExtrasState, Holder: SummaryHolder): boolean
	return ViewOf(State, Holder.Store, Holder.Scope, Holder.Total).Holder == Holder
end

local function NoteHolderUsed(View: TotalView, Clock: number)
	local Holder = View.Holder
	if Holder ~= nil then
		Holder.UsedAt = Clock
	end
end

local function DropHolder(State: ExtrasState, Holder: SummaryHolder)
	local View = ViewOf(State, Holder.Store, Holder.Scope, Holder.Total)
	if View.Holder == Holder then
		View.Holder = nil
	end
	local At = table.find(State.Holders, Holder)
	if At ~= nil then
		table.remove(State.Holders, At)
	end
end

local function NewRequest(Server: ServerState, State: ExtrasState, Purpose: Purpose): number
	local RequestId = Numbers.NewRequestId(Server)
	State.Purposes[RequestId] = Purpose
	return RequestId
end

local function NewCall(State: ExtrasState, Call: TotalCall, Deadline: number): TotalWork
	local Work: TotalWork = { Call = Call, Deadline = Deadline, Waits = {}, IsTakerOwed = false, Tidies = {} }
	State.Calls[Call.CallId] = Work
	return Work
end

local function EndCall(State: ExtrasState, Work: TotalWork)
	State.Calls[Work.Call.CallId] = nil
end

local function TakeWaits(State: ExtrasState, RequestId: number): { TotalWork }
	local Ids: { number } = {}
	for CallId, Work in State.Calls do
		if Work.Waits[RequestId] then
			Work.Waits[RequestId] = nil
			table.insert(Ids, CallId)
		end
	end
	table.sort(Ids)
	local Taken: { TotalWork } = {}
	for _, CallId in Ids do
		table.insert(Taken, State.Calls[CallId])
	end
	return Taken
end

local function OpenCount(State: ExtrasState): number
	local Count = 0
	for _ in State.Calls do
		Count += 1
	end
	Count += CopyState.CopyOpenCount(State.CopyHolders)
	for _ in State.Peeks do
		Count += 1
	end
	for _, Purpose in State.Purposes do
		if Purpose.Kind == "AdviceGet" or Purpose.Kind == "ItemRemove" then
			Count += 1
		end
	end
	return Count
end

return {
	NewState = NewState,
	ViewOf = ViewOf,
	HolderOf = HolderOf,
	NoteHolderUsed = NoteHolderUsed,
	IsHeld = IsHeld,
	DropHolder = DropHolder,
	NewRequest = NewRequest,
	NewCall = NewCall,
	EndCall = EndCall,
	TakeWaits = TakeWaits,
	OpenCount = OpenCount,
}
