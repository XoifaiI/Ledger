--!strict
--!optimize 2

--[=[
	Roll: The list of transactions whose markers still have to go.

	A transaction writes its name here before it opens a marker. No marker exists without a name on
	the roll.
	One key holds every name written in the same minute for one shard. The key carries the minute,
	and the oldest work sorts to the front.

	Return type: A table with Shard, Key, Prefix, At, Mine, Add, RESERVED and SHARDS.
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

local function Add(TxStore: DataStoreWrapper, Txid: string): boolean
	local Named = Key(Txid, Clock.Now())
	local Ok = TxStore:UpdateAsync(Named, function(Current: any): string?
		local Held = if type(Current) == "string" then Mark.Unpack(Current) else {}
		if table.find(Held, Txid) ~= nil then
			return nil
		end

		table.insert(Held, Txid)
		return Mark.Pack(Held)
	end)
	return Ok
end

return table.freeze({
	Shard = Shard,
	Key = Key,
	Prefix = Prefix,
	At = At,
	Mine = Mine,
	Add = Add,

	RESERVED = RESERVED,
	SHARDS = SHARDS,
})
