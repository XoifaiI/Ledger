--!strict
--!optimize 2

--[=[

	Cleanup: The list of transactions whose markers still have to go.

	A transaction writes the key of each marker it may open here before it opens one, so no marker
	exists without one. Names are spread over shards and buckets of time. A key holds up to a limit,
	then the next key of that bucket takes the rest. Any one key costs a bounded read and write. A
	name the reaper looked at and cannot clear yet is carried onto a newer key.

	Each store remembers which part of a bucket to write to next. Two stores keep their own keys, and
	neither one fills the other's.

	A block is a thousand minutes of one shard. Each shard has a mark in the marker store, the oldest
	block that may still hold a key. A name is only ever written in the minute it is written, so a
	block takes no new key once it is sealed, an hour after it ends. The reaper lists from the mark
	and moves it on only past a block it found empty once sealed. A run of blocks that starts on a
	round number is listed with one shorter prefix, ten or a hundred blocks at a time, so a long
	empty stretch costs few listings. Raise only ever moves a mark forward. A shard with no mark
	starts REACH blocks back, as far as the walk back of 6.2.0 went.

	A key has been three shapes. It carried the shard and the minute, then a part number after that,
	and now the server's name before the part. A pass reads all three, since a deploy is not
	instant and a server running the newer build meets keys the older one wrote. Only the newest is
	written, and a name carried forward off an older key lands on a new one, so the old shapes drain
	on their own and never have to be migrated. Every shape starts with the shard and the minute,
	which is all a prefix listing reads, so one listing finds them all.

	Return type: A table with Key, Named, Block, Prefix, Span, Sealed, Open, Low, Raise, At, Mine, Add, Carry and REACH.
	Example usage:
		local Cleanup = require("./Cleanup")
		Cleanup.Add(TxStore, "trade1")
--]=]

local Clock = require("../../Util/Clock")
local DataStoreWrapper = require("../../Util/DataStoreWrapper")
local Datastore = require("../../Core/Constants/Datastore")
local Transactions = require("../../Core/Constants/Transactions")
local Windows = require("../../Core/Constants/Windows")
local Digest = require("../../Encode/Digest")
local Ids = require("../../Encode/Ids")
local Mark = require("../../Encode/Mark")

type DataStoreWrapper = DataStoreWrapper.DataStoreWrapper

local WIDTH = 10
local PART_WIDTH = 3
local SLOT_WIDTH = 2
local BLOCK_WIDTH = 7
local BLOCK = 10 ^ (WIDTH - BLOCK_WIDTH)
local SEAL = Windows.REAP + Windows.REAP_GRACE + Windows.BUCKET
local REACH = Windows.STUCK // (BLOCK * Windows.BUCKET) + 2
local NODE_MOST = Datastore.MAX_KEY - (#Transactions.RESERVED + SLOT_WIDTH + WIDTH + PART_WIDTH + 3)

assert(Transactions.SHARDS <= 10 ^ SLOT_WIDTH, "a cleanup list key writes its shard in two digits, so more shards than that would write keys the reaper cannot read back")
assert(
	BLOCK_WIDTH < WIDTH,
	"a listing prefix is the front of a key's minute, so a block has to be written in fewer digits than the minute it cuts down, or no prefix would ever match a key and nothing would be reaped"
)
assert(
	BLOCK * Windows.BUCKET >= SEAL,
	"a block has to last longer than the hour after it ends in which a late name can still land in it, or two blocks could be open at once and a mark could pass one that still takes keys"
)

local DIGITS = string.rep("%d", WIDTH)
local FORMAT = `{Transactions.RESERVED}%02d:%0{WIDTH}d:%s:%0{PART_WIDTH}d`
local HEAD = `{Transactions.RESERVED}%02d:%0{BLOCK_WIDTH}d`
local LOW = `{Transactions.RESERVED}low:%02d`
local NAMED = `^{Transactions.RESERVED}%d%d:({DIGITS}):%w+:%d+$`
local PARTED = `^{Transactions.RESERVED}%d%d:({DIGITS}):%d+$`
local WHOLE = `^{Transactions.RESERVED}%d%d:({DIGITS})$`
local SHAPES = table.freeze({ NAMED, PARTED, WHOLE })

type Parts = {
	At: number,
	Slots: { [number]: number },
}

local Filled: { [DataStoreWrapper]: Parts } = setmetatable({}, { __mode = "k" }) :: any

local function Mine(Node: string?): number
	return Digest.Bucket(Node or Ids.Home(), Transactions.SHARDS)
end

local function Named(Slot: number, When: number, Node: string, Part: number): string
	assert(
		type(Node) == "string" and #Node > 0 and #Node <= NODE_MOST and string.find(Node, "^%w+$") ~= nil,
		`a cleanup list key carries the server's name, and '{tostring(Node)}' is not one of 1 to {NODE_MOST} letters and digits`
	)
	return string.format(FORMAT, Slot, When // Windows.BUCKET, Node, Part)
end

local function Key(Node: string, When: number): string
	return Named(Mine(Node), When, Node, 1)
end

local function Block(When: number): number
	return When // Windows.BUCKET // BLOCK
end

local function Prefix(Slot: number, Held: number): string
	return string.format(HEAD, Slot, Held)
end

local function Span(Slot: number, First: number, Last: number): (string, number)
	local Size = 1
	local Digits = BLOCK_WIDTH
	while Digits > 1 and First % (Size * 10) == 0 and First + Size * 10 - 1 <= Last do
		Size *= 10
		Digits -= 1
	end
	return string.format(`{Transactions.RESERVED}%02d:%0{Digits}d`, Slot, First // Size), Size
end

local function Sealed(Held: number, Now: number): boolean
	return Now - (Held + 1) * BLOCK * Windows.BUCKET >= SEAL
end

local function Open(Now: number): number
	local Current = Block(Now)
	return if Sealed(Current - 1, Now) then Current else Current - 1
end

local function Low(Slot: number): string
	return string.format(LOW, Slot)
end

local function Raise(TxStore: DataStoreWrapper, Slot: number, To: number): boolean
	local Ok = TxStore:UpdateAsync(Low(Slot), function(Current: any): number?
		if type(Current) == "number" and Current >= To then
			return nil
		end
		return To
	end)
	return Ok
end

local function At(Held: string): number?
	for _, Shape in SHAPES do
		local Digits = string.match(Held, Shape)
		local Minutes = if Digits ~= nil then tonumber(Digits) else nil
		if Minutes ~= nil then
			return Minutes * Windows.BUCKET
		end
	end
	return nil
end

local function Place(TxStore: DataStoreWrapper, Slot: number, Node: string, When: number, Batch: { string }): boolean
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
		local Ok = TxStore:UpdateAsync(Named(Slot, When, Node, Part), function(Current: any): string?
			Placed = 0
			local Held = if type(Current) == "string" then Mark.Unpack(Current) else {}
			if type(Current) == "string" and #Current > 0 and #Held == 0 then
				warn(
					`Ledger: the cleanup list key '{Named(Slot, When, Node, Part)}' is not a list of names, so it is left alone. this transaction goes on the next key. whatever was on it cannot be read back`
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

local function Carry(TxStore: DataStoreWrapper, Slot: number, Node: string, Txids: { string }): boolean
	return Place(TxStore, Slot, Node, Clock.Now(), Txids)
end

local function Add(TxStore: DataStoreWrapper, Node: string, Txid: string): boolean
	return Carry(TxStore, Mine(Node), Node, { Txid })
end

return table.freeze({
	Key = Key,
	Named = Named,
	Block = Block,
	Prefix = Prefix,
	Span = Span,
	Sealed = Sealed,
	Open = Open,
	Low = Low,
	Raise = Raise,
	At = At,
	Mine = Mine,
	Add = Add,
	Carry = Carry,
	REACH = REACH,
})
