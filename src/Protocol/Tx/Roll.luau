--!strict
--!optimize 2

--[=[
	Roll: The list of transactions whose markers still have to go.

	A transaction writes its name here before it opens a marker. No marker exists without a name on
	the roll.
	One key holds every name written in the same minute for one shard. The key carries the minute,
	and the oldest work sorts to the front.
	A name the reaper cannot clear yet moves to a key of the minute it was read in. An old key is
	therefore always emptied and taken away.

	Return type: A table with Shard, Key, Prefix, At, Mine, Add, Carry, RESERVED and SHARDS.
	Example usage:
		local Roll = require("./Roll")
		Roll.Add(TxStore, "trade1")
--]=]

local EncodingService = game:GetService("EncodingService")

local Clock = require("../../Util/Clock")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local Ident = require("../../Encode/Ident")
local Mark = require("../../Encode/Mark")

type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper

local RESERVED = "__"
local SHARDS = 32
local MINUTE = 60
local WIDTH = 10

local DIGITS = string.rep("%d", WIDTH)
local FORMAT = `{RESERVED}%02d:%0{WIDTH}d`
local HEAD = `{RESERVED}%02d:`
local PATTERN = `^{RESERVED}%d%d:({DIGITS})$`
local ALGORITHM = Enum.HashAlgorithm.Blake3

local LastNode = ""
local LastShard = 0

local function Shard(Text: string): number
	return string.byte(EncodingService:ComputeStringHash(Text, ALGORITHM), 1) % SHARDS
end

local function Key(Txid: string, When: number): string
	return string.format(FORMAT, Shard(Txid), When // MINUTE)
end

local function Prefix(Slot: number): string
	return string.format(HEAD, Slot)
end

local function At(Named: string): number?
	local Digits = string.match(Named, PATTERN)
	if Digits == nil then
		return nil
	end

	local Minutes = tonumber(Digits)
	if Minutes == nil then
		return nil
	end
	return Minutes * MINUTE
end

local function Mine(): number
	local Home = Ident.Home()
	if Home ~= LastNode then
		LastNode = Home
		LastShard = Shard(Home)
	end
	return LastShard
end

local function Carry(TxStore: DataStoreWrapper, Txids: { string }): boolean
	local Now = Clock.Now()
	local Grouped: { [string]: { string } } = {}
	for _, Txid in Txids do
		local Named = Key(Txid, Now)
		local Batch = Grouped[Named]
		if Batch == nil then
			Batch = {}
			Grouped[Named] = Batch
		end
		table.insert(Batch, Txid)
	end

	local Every = true
	for Named, Batch in Grouped do
		local Ok = TxStore:UpdateAsync(Named, function(Current: any): string?
			local Held = if type(Current) == "string" then Mark.Unpack(Current) else {}
			local Added = false
			for _, Txid in Batch do
				if table.find(Held, Txid) == nil then
					table.insert(Held, Txid)
					Added = true
				end
			end

			if not Added then
				return nil
			end
			return Mark.Pack(Held)
		end)
		Every = Every and Ok
	end
	return Every
end

local function Add(TxStore: DataStoreWrapper, Txid: string): boolean
	return Carry(TxStore, { Txid })
end

return table.freeze({
	Shard = Shard,
	Key = Key,
	Prefix = Prefix,
	At = At,
	Mine = Mine,
	Add = Add,
	Carry = Carry,

	RESERVED = RESERVED,
	SHARDS = SHARDS,
})
