--!strict
--!optimize 2

--[=[
	Reap: Removes the markers of transactions that are over.

	Every transaction writes its name on the roll before it opens a marker, so a pass reads the roll
	and never searches the store.
	A marker goes only once every key it named has forgotten its leg, and a key that cannot be read
	counts as still holding one. One already finished goes on a shorter window than one still being
	decided. A delete names no generation, so it can land on a marker opened under the same name
	after this pass read it, which costs that transaction a retry and never a leg.

	A pass reads a fixed number of names per shard, stops at a cap or when either store runs short of
	budget, and gives back the shard it stopped on so the next one starts there. A name it could not
	reach goes to the front of the next key.

	Return type: A table with Reap, Spent, Quiet, Anywhere, REAP_HORIZON, REAP_GRACE, REAP_LIMIT, REAP_LOOKS, REAP_PAGE and REAP_FLOOR. The type is Reaping.
	Example usage:
		local Reap = require("./Reap")
		local Count, Next = Reap.Reap(TxStore, Lookup)
--]=]

local Say = require("../../Util/Tools/Say")
local Clock = require("../../Util/Engine/Clock")
local DataStoreWrapper = require("../../Util/Engine/DataStoreWrapper")
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
local STUCK_HORIZON = Horizons.STUCK
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

local function Anywhere(Lookup: Lookup, Name: string): LogTypes.Log
	local Known = Lookup(Name)
	if Known ~= nil then
		return Known
	end
	return Log.New(Marker.Elsewhere(Name))
end

local function Quiet(Txid: string, Keys: any, Lookup: Lookup, Gen: string?, Born: number): (boolean, boolean)
	if type(Keys) ~= "string" or #Keys == 0 then
		return false, false
	end

	local Named = Mark.Unpack(Keys)
	if #Named == 0 then
		return false, false
	end

	for _, Held in Named do
		local Store, Key = Mark.Split(Held)
		if Store == nil or Key == nil then
			return false, false
		end

		local Read, Record = pcall(function(): Record
			return Anywhere(Lookup, Store):Read(Key :: string)
		end)
		if not Read or not Spent(Record, Txid, Gen, Born) then
			return false, true
		end
	end

	return true, true
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

		if not Settled then
			local Hushed, Readable = Quiet(Txid, Held.Keys, Lookup, Marker.GenOf(Value), Marker.BornAt(Value, 0))
			if not Hushed and Readable then
				return false, false
			end

			if not Hushed and Now - Updated <= STUCK_HORIZON then
				Say.Warn(
					`Ledger: transaction '{Txid}' names no keys Ledger can read, so nothing can prove its legs are finished and it is read again on every pass until it is {STUCK_HORIZON // 86400} days old. there may be more of these than the one named here. take them off by hand once every key they touched has forgotten them`
				)
				return false, false
			end

			if not Hushed then
				Say.Warn(
					`Ledger: transaction '{Txid}' names no keys Ledger can read and nothing has touched it for {STUCK_HORIZON // 86400} days, so nothing can ever prove its legs are finished and it is taken off rather than read for good. a leg of it still parked somewhere settles as cancelled now, so check the audit log`
				)
			end
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
	STUCK_HORIZON = STUCK_HORIZON,
	REAP_LIMIT = REAP_LIMIT,
	REAP_LOOKS = REAP_LOOKS,
	REAP_PAGE = REAP_PAGE,
	REAP_FLOOR = REAP_FLOOR,
})
