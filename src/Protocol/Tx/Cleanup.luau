--!strict
--!optimize 2

--[=[

	Cleanup: The list of transactions whose markers still have to go.

	A transaction writes its name here before it opens a marker, so no marker exists without one. Names
	are spread over shards and buckets of time, and a key holds up to a limit before the next key of
	that bucket takes the rest, so any one key costs a bounded read and write. A name the reaper cannot
	clear yet is carried onto a newer key. Which part of a bucket to write to next is remembered per
	store, since two stores keep their own keys and neither one fills the other's.

	Return type: A table with Shard, Key, Named, Prefix, At, Mine, Add and Carry.
	Example usage:
		local Cleanup = require("./Cleanup")
		Cleanup.Add(TxStore, "trade1")
--]=]

local Clock = require("../../Util/Clock")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local Transactions = require("../../Core/Constants/Transactions")
local Windows = require("../../Core/Constants/Windows")
local Digest = require("../../Encode/Digest")
local Ids = require("../../Encode/Ids")
local Mark = require("../../Encode/Mark")

type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper

local WIDTH = 10
local PART_WIDTH = 3

local DIGITS = string.rep("%d", WIDTH)
local FORMAT = `{Transactions.RESERVED}%02d:%0{WIDTH}d:%0{PART_WIDTH}d`
local HEAD = `{Transactions.RESERVED}%02d:`
local PATTERN = `^{Transactions.RESERVED}%d%d:({DIGITS}):%d+$`
local PLAIN = `^{Transactions.RESERVED}%d%d:({DIGITS})$`

type Parts = {
	At: number,
	Slots: { [number]: number },
}

local LastNode = ""
local LastShard = 0

local Filled: { [DataStoreWrapper]: Parts } = setmetatable({}, { __mode = "k" }) :: any

local function Shard(Text: string): number
	return Digest.Bucket(Text, Transactions.SHARDS)
end

local function Named(Slot: number, When: number, Part: number): string
	return string.format(FORMAT, Slot, When // Windows.BUCKET, Part)
end

local function Key(Txid: string, When: number): string
	return Named(Shard(Txid), When, 1)
end

local function Prefix(Slot: number): string
	return string.format(HEAD, Slot)
end

local function At(Held: string): number?
	local Digits = string.match(Held, PATTERN) or string.match(Held, PLAIN)
	if Digits == nil then
		return nil
	end

	local Minutes = tonumber(Digits)
	if Minutes == nil then
		return nil
	end
	return Minutes * Windows.BUCKET
end

local function Mine(Node: string?): number
	local Home = Node or Ids.Home()
	if Home ~= LastNode then
		LastNode = Home
		LastShard = Shard(Home)
	end
	return LastShard
end

local function Place(TxStore: DataStoreWrapper, Slot: number, When: number, Batch: { string }): boolean
	local Minute = When // Windows.BUCKET
	local Hint = Filled[TxStore]
	if Hint == nil then
		Hint = { At = Minute, Slots = {} }
		Filled[TxStore] = Hint
	end
	if Hint.At ~= Minute then
		table.clear(Hint.Slots)
		Hint.At = Minute
	end

	local Left = Batch
	local Part = Hint.Slots[Slot] or 1

	while #Left > 0 and Part <= Transactions.PARTS do
		local Placed = 0
		local Ok = TxStore:UpdateAsync(Named(Slot, When, Part), function(Current: any): string?
			Placed = 0
			local Held = if type(Current) == "string" then Mark.Unpack(Current) else {}
			if type(Current) == "string" and #Current > 0 and #Held == 0 then
				warn(
					`Ledger: the cleanup list key '{Named(Slot, When, Part)}' holds something that is not a list of names, so it is left alone rather than written over and this transaction goes on the next key of the minute. whatever was on it cannot be read back`
				)
				return nil
			end
			local Known: { [string]: boolean } = {}
			for _, Txid in Held do
				Known[Txid] = true
			end

			local Added = false
			for _, Txid in Left do
				if Known[Txid] then
					Placed += 1
					continue
				end
				if #Held >= Transactions.ROLL_LIMIT then
					break
				end

				Known[Txid] = true
				table.insert(Held, Txid)
				Added = true
				Placed += 1
			end

			if not Added then
				return nil
			end
			return Mark.Pack(Held)
		end)

		if not Ok then
			return false
		end
		if Placed >= #Left then
			return true
		end

		Left = table.move(Left, Placed + 1, #Left, 1, {})
		Part += 1
		Hint.Slots[Slot] = Part
	end

	return #Left == 0
end

local function Carry(TxStore: DataStoreWrapper, Txids: { string }): boolean
	local Now = Clock.Now()
	local Grouped: { [number]: { string } } = {}
	for _, Txid in Txids do
		local Slot = Shard(Txid)
		local Batch = Grouped[Slot]
		if Batch == nil then
			Batch = {}
			Grouped[Slot] = Batch
		end
		table.insert(Batch, Txid)
	end

	local Every = true
	for Slot, Batch in Grouped do
		Every = Place(TxStore, Slot, Now, Batch) and Every
	end
	return Every
end

local function Add(TxStore: DataStoreWrapper, Txid: string): boolean
	return Carry(TxStore, { Txid })
end

return table.freeze({
	Shard = Shard,
	Key = Key,
	Named = Named,
	Prefix = Prefix,
	At = At,
	Mine = Mine,
	Add = Add,
	Carry = Carry,
})
