--!strict
--!optimize 2

--[=[

	Reap: Removes the markers of transactions that are over.

	A pass reads the cleanup list rather than searching the store. A marker goes only once every key
	it named has forgotten its leg, and only once it is condemned under the generation and the status
	the pass judged. Nothing writes the key of a marker twice, so the remove takes off only that one.
	A key it cannot read counts as still holding one. Each pass reads a fixed number of names per
	shard and gives back where it stopped.

	A pass with a Claim asks it before each shard and skips a shard another server holds. A skipped
	shard still counts as walked. A walk back claims the older block it is due to list apart from the
	shard, so the servers whose walks meet on one block list it once between them. A server that finds
	that block claimed counts it as walked, and one whose shard is held elsewhere still lists the block
	it claimed. Servers that meet on a shard would otherwise stall each other's walk back, and an old
	marker could wait for weeks. A Bounded pass whose Claim cannot reach its map stops after one shard
	and gives back the next one. One server still covers every shard, over as many passes as there are
	shards. Only the background pass is bounded. An operator gets the whole walk.

	Three questions run the pass and each answers one word rather than a pair of flags. Reading the
	keys a marker names proves it Finished, still Holding, or Unreadable. A marker is then Kept for a
	later pass, found already Gone, or Reaped. Listing a block of the cleanup list ends Done, Full
	when there is no room left to look, or Stopped when something outside the pass gave out. Only
	Stopped ends the whole walk.

	Return type: A table with Reap. The type is Reaping.
	Example usage:
		local Reap = require("./Reap")
		local Count, Next = Reap.Reap(TxStore, Lookup)
--]=]

local Clock = require("../../Util/Clock")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local Shapes = require("../../Core/Shapes")
local Transactions = require("../../Core/Constants/Transactions")
local Windows = require("../../Core/Constants/Windows")
local Ids = require("../../Encode/Ids")
local Mark = require("../../Encode/Mark")
local Log = require("../../Record/Log")
local LogTypes = require("../../Record/Types")
local Marker = require("./Marker")
local Cleanup = require("./Cleanup")
local Types = require("./Types")

type Record = Shapes.Record<any>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Lookup = Types.Lookup
type Claimed = Types.Claimed

export type Bookmark = {
	Shard: number,
	Prefix: string,
	Cursor: string,
}

export type Reaping = {
	Node: string?,
	From: number?,
	Horizon: number?,
	Limit: number?,
	Shards: number?,
	Older: { Shard: number, Back: number, Cursor: Bookmark? }?,
	Afford: (() -> boolean)?,
	Claim: ((Shard: number, Block: number?) -> Claimed)?,
}

type Walk = {
	TxStore: DataStoreWrapper,
	Lookup: Lookup,
	Node: string,
	Shard: number,
	Now: number,
	Older: number,
	Grace: number,
	Room: number,
	Looked: number,
	Reaped: number,
	Afford: (() -> boolean)?,
}

local ABSENT: Claimed = { Outcome = Transactions.ABSENT }
table.freeze(ABSENT)

local ONCE = DataStoreWrapper.ONCE

type Proof = "Finished" | "Holding" | "Unreadable"
type Fate = "Keep" | "Gone" | "Reaped"
type Ending = "Done" | "Full" | "Stopped"

local FINISHED: Proof = "Finished"
local HOLDING: Proof = "Holding"
local UNREADABLE: Proof = "Unreadable"

local KEEP: Fate = "Keep"
local WENT: Fate = "Gone"
local REAPED: Fate = "Reaped"

local DONE: Ending = "Done"
local FULL: Ending = "Full"
local STOPPED: Ending = "Stopped"

local function Affords(Walk: Walk): boolean
	local Afford = Walk.Afford
	return Afford == nil or Afford()
end

local function Spent(Record: Record, Txid: string, Gen: string?, Born: number): boolean
	for _, Op in Record.Ops do
		if Op.Tx ~= Txid then
			continue
		end
		if type(Gen) ~= "string" then
			return false
		end

		local Mine = Op.TxGen
		if type(Mine) ~= "string" or Mine == Gen then
			return false
		end
		if type(Op.TxAt) ~= "number" or Op.TxAt >= Born then
			return false
		end
	end
	return true
end

local function Anywhere(Walk: Walk, Name: string): LogTypes.Log
	local Known = Walk.Lookup(Name)
	if Known ~= nil then
		return Known
	end
	return Log.New(Marker.Elsewhere(Name, Walk.TxStore))
end

local function Quiet(Walk: Walk, Txid: string, Keys: any, Gen: string?, Born: number): Proof
	if type(Keys) ~= "string" or #Keys == 0 then
		return UNREADABLE
	end

	local Named = Mark.Unpack(Keys)
	if #Named == 0 then
		return UNREADABLE
	end

	for _, Held in Named do
		local Store, Key = Mark.Split(Held)
		if Store == nil or Key == nil then
			return UNREADABLE
		end

		local Read, Record = pcall(function(): Record
			return (Anywhere(Walk, Store):Read(Key :: string))
		end)
		if not Read or not Spent(Record, Txid, Gen, Born) then
			return HOLDING
		end
	end

	return FINISHED
end

local function Stuck(Txid: string, Ageing: boolean)
	if Ageing then
		warn(
			`Ledger: transaction '{Txid}' names no keys Ledger can read, so nothing can prove it is finished. Ledger reads it again every pass until it is {Windows.STUCK // Windows.DAY} days old. there may be more of these than the one named here. take them off by hand once every key they touched has forgotten them`
		)
		return
	end

	warn(
		`Ledger: transaction '{Txid}' names no keys Ledger can read and nothing has touched it for {Windows.STUCK // Windows.DAY} days. nothing can ever prove it is finished, so it is taken off for good. any part of it still waiting on a key settles as cancelled now, check the audit log`
	)
end

local function Judged(Walk: Walk, Txid: string, Value: any, Updated: number): boolean
	local Held = Value :: Types.Marker
	local Settled = Held.Dead == true or Held.Status == Transactions.ABORTED
	if Walk.Now - Updated < (if Settled then Walk.Grace else Walk.Older) then
		return false
	end
	if Settled then
		return true
	end

	local Shown = Quiet(Walk, Txid, Held.Keys, Marker.GenOf(Value), Marker.BornAt(Value, 0))
	if Shown == FINISHED then
		return true
	end
	if Shown == HOLDING then
		return false
	end

	local Ageing = Walk.Now - Updated <= Windows.STUCK
	Stuck(if type(Held.Name) == "string" then Held.Name else Txid, Ageing)
	return not Ageing
end

local function Doomed(Walk: Walk, Txid: string, Value: any, Info: any): boolean
	if Marker.Condemned(Value) then
		return true
	end
	if type(Value) == "table" and not Judged(Walk, Txid, Value, Marker.TouchedAt(Info)) then
		return false
	end
	return Marker.Condemn(Walk.TxStore, Txid, Value)
end

local function Gone(Walk: Walk, Txid: string): Fate
	local Read, Value, Info = Walk.TxStore:GetAsync(Txid)
	if not Read then
		return KEEP
	end
	if Value == nil then
		return WENT
	end
	if not Doomed(Walk, Txid, Value, Info) then
		return KEEP
	end

	if not Walk.TxStore:RemoveAsync(Txid, nil, ONCE) then
		return KEEP
	end
	return REAPED
end

local function Sweep(Walk: Walk, Named: string, Looks: number): (number, number)
	if Looks <= 0 or not Affords(Walk) then
		return 0, 0
	end

	local Read, Packed = Walk.TxStore:GetAsync(Named)
	if not Read or type(Packed) ~= "string" then
		return 0, 0
	end

	local Held = Mark.Unpack(Packed)
	local Later: { string } = {}
	local Kept: { string } = {}
	local Room = Walk.Room - Walk.Reaped
	local Reaped = 0
	local Looked = 0

	for Index, Txid in Held do
		if Looked >= Looks or Reaped >= Room or not Affords(Walk) then
			table.move(Held, Index, #Held, #Later + 1, Later)
			break
		end

		Looked += 1
		local Answer = Gone(Walk, Txid)
		if Answer == KEEP then
			table.insert(Kept, Txid)
			continue
		end
		if Answer == REAPED then
			Reaped += 1
		end
	end

	if Looked == 0 and #Held > 0 then
		return 0, 0
	end

	for _, Txid in Kept do
		table.insert(Later, Txid)
	end

	if #Later == 0 then
		Walk.TxStore:RemoveAsync(Named)
		return Reaped, Looked
	end
	if Cleanup.Carry(Walk.TxStore, Walk.Shard, Walk.Node, Later) then
		Walk.TxStore:RemoveAsync(Named)
	end
	return Reaped, Looked
end

local function Full(Walk: Walk, Looks: number): boolean
	return Walk.Reaped >= Walk.Room or Looks <= 0
end

local function Listed(Walk: Walk, Prefix: string, Looks: number, From: string?): (Ending, string?)
	local Ok, Pages = Walk.TxStore:ListKeysAsync(Prefix, Transactions.REAP_PAGE, From, nil, ONCE)
	if not Ok then
		return STOPPED, nil
	end

	local Book = Pages :: DataStoreKeyPages
	while true do
		for _, Entry in Book:GetCurrentPage() do
			if Full(Walk, Looks) then
				return FULL, Book.Cursor
			end

			local Named = (Entry :: any).KeyName
			local At = Cleanup.At(Named)
			if At == nil or Walk.Now - At < Walk.Grace then
				continue
			end

			local Took, Looked = Sweep(Walk, Named, Looks)
			Walk.Reaped += Took
			Walk.Looked += Looked
			Looks -= Looked
		end

		if Book.IsFinished then
			return DONE, nil
		end
		if not Affords(Walk) then
			return STOPPED, Book.Cursor
		end
		if not pcall(Book.AdvanceToNextPageAsync, Book) then
			return STOPPED, nil
		end
	end
end

local function Marked(Shard: number, Prefix: string, Cursor: string?): Bookmark?
	if Cursor == nil or Cursor == "" then
		return nil
	end
	return { Shard = Shard, Prefix = Prefix, Cursor = Cursor }
end

local function Reap(TxStore: DataStoreWrapper, Lookup: Lookup, Held: Reaping?): (number, number, boolean, Bookmark?)
	local Asked: Reaping = Held or {}
	local Older = Asked.Horizon or Windows.REAP
	local Walk: Walk = {
		TxStore = TxStore,
		Lookup = Lookup,
		Node = Asked.Node or Ids.Home(),
		Shard = 0,
		Now = Clock.Now(),
		Older = Older,
		Grace = math.min(Older, Windows.REAP_GRACE),
		Room = Asked.Limit or Transactions.REAP_LIMIT,
		Looked = 0,
		Reaped = 0,
		Afford = Asked.Afford,
	}
	local Claim = Asked.Claim
	local Own = Cleanup.Mine(Walk.Node)
	local Base = if type(Asked.From) == "number" then Asked.From % Transactions.SHARDS else Own

	local Count = math.min(Asked.Shards or Transactions.SHARDS, Transactions.SHARDS)
	local Share = math.max(Transactions.REAP_LOOKS, Walk.Room // Count)
	local Cursor = Asked.Older
	local Bookmark = if Cursor ~= nil then Cursor.Cursor else nil
	local Rotated = false
	local Pending: Bookmark? = Bookmark

	local Step = 0
	while Step < Count do
		if Walk.Reaped >= Walk.Room or Walk.Looked >= Walk.Room or not Affords(Walk) then
			break
		end

		local Shard = (Base + Step) % Transactions.SHARDS
		Walk.Shard = Shard
		local Lease: Claimed = if Claim ~= nil then Claim(Shard) else ABSENT
		local Left = Walk.Room - Walk.Looked
		local Looks = if Lease.Outcome == Transactions.TAKEN or Shard == Own then Left else math.min(Share, Left)
		local Back = if Cursor ~= nil and Cursor.Shard == Shard then Cursor.Back else nil
		local Aside: Claimed = if Back ~= nil and Claim ~= nil then Claim(Shard, Cleanup.Block(Walk.Now) - Back) else ABSENT
		local Walked = Aside.Outcome == Transactions.HELD
		local Ended: Ending = DONE
		if Pending ~= nil and Pending.Shard == Shard then
			Pending = nil
		end
		if Back ~= nil and Walked then
			Rotated = true
		end
		local Due = if Walked then nil else Back
		local Prefixes = if Lease.Outcome == Transactions.HELD then Cleanup.Older(Shard, Walk.Now, Due) else Cleanup.Blocks(Shard, Walk.Now, Due)
		for Index, Prefix in Prefixes do
			local From = if Bookmark ~= nil and Bookmark.Shard == Shard and Bookmark.Prefix == Prefix then Bookmark.Cursor else nil
			local Rest
			Ended, Rest = Listed(Walk, Prefix, Looks, From)
			Pending = Marked(Shard, Prefix, Rest)
			if Back ~= nil and Index == #Prefixes and Ended ~= STOPPED then
				Rotated = true
			end
			if Ended ~= DONE then
				break
			end
		end
		if Lease.Outcome == Transactions.TAKEN and Ended ~= DONE then
			Lease.Release()
		end
		if Aside.Outcome == Transactions.TAKEN and Ended ~= DONE then
			Aside.Release()
		end
		if Ended == STOPPED then
			return Walk.Reaped, Shard, Rotated, Pending
		end

		Step += 1
	end

	return Walk.Reaped, (Base + Step) % Transactions.SHARDS, Rotated, Pending
end

return table.freeze({
	Reap = Reap,
})
