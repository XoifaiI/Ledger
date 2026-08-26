--!strict
--!optimize 2

--[=[
	Reap: Removes the markers of transactions that are over.

	Every transaction writes its name on the roll before it opens a marker. A pass reads the roll and
	never searches the store.
	A committed marker can go only after each key that it touched has forgotten it. A key that still
	names the marker would read the missing marker as an abort, and would undo a committed leg.
	A buried marker is already finished, so it goes on age alone, and it goes on a shorter window than
	one that is still being decided. This is the one place that takes a
	marker away. A delete names no generation, so it can still land on a marker made under the same
	name after this pass read it. That costs the new transaction a retry and never a leg, because a
	missing marker only aborts legs older than the whole transaction, and the new one's are not.
	A key that a pass cannot read counts as loud, so a datastore fault never removes a marker early.
	One pass walks the shards until it has taken enough away or the budget runs short, and gives back
	the shard it stopped on. The next pass starts there, so no shard waits behind the ones in front of
	it forever. A server with no pass behind it starts on the shard it hashes to.
	A name it cannot clear moves on to a newer key, so an old key always empties.
	A pass reads a fixed number of names per shard. A name it did not reach goes to the front of the
	next key, so a name that can never be cleared cannot hold the ones behind it.
	Deciding a marker reads the keys it named, which are in the store the records live in and not this
	one. A pass therefore spends from two budgets, and asks about both before each shard.

	Return type: A table with Reap, Spent, Quiet, Anywhere, REAP_HORIZON, REAP_GRACE, REAP_LIMIT, REAP_LOOKS, REAP_PAGE and REAP_FLOOR. The type is Reaping.
	Example usage:
		local Reap = require("./Reap")
		local Count, Next = Reap.Reap(TxStore, Lookup)
--]=]

local Clock = require("../../Util/Clock")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local Contract = require("../../Contract/Op")
local Horizons = require("../../Contract/Horizons")
local Mark = require("../../Encode/Mark")
local Log = require("../../Record/Log")
local LogTypes = require("../../Record/Types")
local Marker = require("./Marker")
local Roll = require("./Roll")
local Types = require("./Types")

type Record = Contract.Record<any>
type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper
type Lookup = Types.Lookup

local REAP_HORIZON = Horizons.REAP
local REAP_GRACE = Horizons.REAP_GRACE
local REAP_LIMIT = 64
local REAP_LOOKS = 16
local REAP_PAGE = 64
local REAP_FLOOR = REAP_LOOKS + 2

export type Reaping = {
	From: number?,
	Horizon: number?,
	Limit: number?,
	Afford: (() -> boolean)?,
}

local function Spent(Record: Record, Txid: string, Gen: string?, Born: number): boolean
	if type(Gen) ~= "string" then
		return false
	end

	for _, Op in Record.Ops do
		if Op.Tx ~= Txid then
			continue
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

local function Anywhere(Lookup: Lookup, Name: string): LogTypes.Log
	local Known = Lookup(Name)
	if Known ~= nil then
		return Known
	end
	return Log.New(Marker.Elsewhere(Name))
end

local function Quiet(Txid: string, Keys: any, Lookup: Lookup, Gen: string?, Born: number): boolean
	if type(Keys) ~= "string" or #Keys == 0 then
		return false
	end

	for _, Held in Mark.Unpack(Keys) do
		local Store, Key = Mark.Split(Held)
		if Store == nil or Key == nil then
			return false
		end

		local Records = Anywhere(Lookup, Store)
		local Read, Record = pcall(function(): Record
			return Records:Read(Key :: string)
		end)
		if not Read or not Spent(Record, Txid, Gen, Born) then
			return false
		end
	end

	return true
end

local function Gone(TxStore: DataStoreWrapper, Txid: string, Lookup: Lookup, Now: number, Older: number, Grace: number): (boolean, boolean)
	local Read, Value, Info = TxStore:GetAsync(Txid)
	if not Read then
		return false, false
	end
	if Value == nil then
		return true, false
	end

	if type(Value) == "table" then
		local Held = Value :: Types.Marker
		local Updated = if Info then (Info :: DataStoreKeyInfo).UpdatedTime / 1000 else 0
		local Settled = Held.Dead == true or Held.Status == Marker.ABORTED
		if Now - Updated < (if Settled then Grace else Older) then
			return false, false
		end
		if not Settled and not Quiet(Txid, Held.Keys, Lookup, Marker.GenOf(Value), Marker.BornAt(Value, 0)) then
			return false, false
		end
	end

	if not TxStore:RemoveAsync(Txid) then
		return false, false
	end
	return true, true
end

local function Sweep(TxStore: DataStoreWrapper, Lookup: Lookup, Named: string, Now: number, Older: number, Grace: number, Room: number, Looks: number): (number, number)
	local Read, Packed = TxStore:GetAsync(Named)
	if not Read or type(Packed) ~= "string" then
		return 0, 0
	end

	local Held = Mark.Unpack(Packed)
	local Later: { string } = {}
	local Kept: { string } = {}
	local Reaped = 0
	local Looked = 0

	for Index, Txid in Held do
		if Looked >= Looks or Reaped >= Room then
			table.move(Held, Index, #Held, #Later + 1, Later)
			break
		end

		Looked += 1
		local Drop, Took = Gone(TxStore, Txid, Lookup, Now, Older, Grace)
		if not Drop then
			table.insert(Kept, Txid)
			continue
		end
		if Took then
			Reaped += 1
		end
	end

	for _, Txid in Kept do
		table.insert(Later, Txid)
	end

	if #Later == 0 then
		TxStore:RemoveAsync(Named)
		return Reaped, Looked
	end
	if Roll.Carry(TxStore, Later) then
		TxStore:RemoveAsync(Named)
	end
	return Reaped, Looked
end

local function Reap(TxStore: DataStoreWrapper, Lookup: Lookup, Held: Reaping?): (number, number)
	local Asked: Reaping = Held or {}
	local Older = Asked.Horizon or REAP_HORIZON
	local Grace = math.min(Older, REAP_GRACE)
	local Room = Asked.Limit or REAP_LIMIT
	local Afford = Asked.Afford
	local Now = Clock.Now()
	local Base = if type(Asked.From) == "number" then Asked.From % Roll.SHARDS else Roll.Mine()

	local Reaped = 0
	local Step = 0
	while Step < Roll.SHARDS do
		if Reaped >= Room or (Afford ~= nil and not Afford()) then
			break
		end

		local Ok, Pages = TxStore:ListKeysAsync(Roll.Prefix((Base + Step) % Roll.SHARDS), REAP_PAGE, nil)
		if Ok then
			local Looks = REAP_LOOKS
			local Book = Pages :: DataStoreKeyPages
			while true do
				local Stop = false
				for _, Entry in Book:GetCurrentPage() do
					local Named = (Entry :: any).KeyName
					local At = Roll.At(Named)
					if At == nil then
						continue
					end
					if Now - At < Grace or Reaped >= Room or Looks <= 0 then
						Stop = true
						break
					end

					local Took, Looked = Sweep(TxStore, Lookup, Named, Now, Older, Grace, Room - Reaped, Looks)
					Reaped += Took
					Looks -= Looked
				end

				if Stop or Book.IsFinished or Reaped >= Room then
					break
				end
				if not pcall(Book.AdvanceToNextPageAsync, Book) then
					break
				end
			end
		end

		Step += 1
	end

	return Reaped, (Base + Step) % Roll.SHARDS
end

return table.freeze({
	Reap = Reap,
	Spent = Spent,
	Quiet = Quiet,
	Anywhere = Anywhere,
	REAP_HORIZON = REAP_HORIZON,
	REAP_GRACE = REAP_GRACE,
	REAP_LIMIT = REAP_LIMIT,
	REAP_LOOKS = REAP_LOOKS,
	REAP_PAGE = REAP_PAGE,
	REAP_FLOOR = REAP_FLOOR,
})
