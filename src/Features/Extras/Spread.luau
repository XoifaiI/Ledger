--!strict
--!optimize 2

--[=[
	Spread: how a copy's or a summary's replicas are named and shared out (extras sheet E7 to E9). Replica 0 is the
	item's own key and replica r that key, the replica infix and r; a cold key, which nobody writes, is the item's
	key, the cold suffix and a slot, so a read of it answers only whether MemoryStore answers. A server's slot of an
	item spreads servers over ReplicasMost, and its home under a count of replicas is its slot modulo the count, so
	a doubling count keeps half the homes in place; the cold keys are spread the same way, so many failing readers
	do not make one hot. A server with no number yet has slot 0. A count grows by ReplicaFactor up to ReplicasMost.

	Return type: A plain table of functions.
	Example usage:
		local Home = Spread.HomeOf(Spread.SlotOf(Encoding, ItemKey, ServerNumber), Count)
--]=]

local Extras = require("../../Record/Constants/Extras")
local HashInputs = require("../../Record/Encoding/HashInputs")
local Record = require("../../Record/Constants/Record")

type Encoding = HashInputs.Encoding

local ReplicasMost = Extras.ReplicasMost
local ReplicaFactor = Extras.ReplicaFactor
local ReplicaKeyInfix = Record.ReplicaKeyInfix
local ColdKeySuffix = Record.ColdKeySuffix

local function ReplicaKey(ItemKey: string, Replica: number): string
	if Replica == 0 then
		return ItemKey
	end
	return `{ItemKey}{ReplicaKeyInfix}{Replica}`
end

local function SlotOf(Encoding: Encoding, ItemKey: string, ServerNumber: number?): number
	if ServerNumber == nil then
		return 0
	end
	local Digest = HashInputs.Hash(Encoding, HashInputs.HomeReplicaInput(ItemKey, ServerNumber))
	return HashInputs.ChoiceNumber(Digest) % ReplicasMost
end

local function HomeOf(Slot: number, Count: number): number
	return Slot % Count
end

local function ColdKey(ItemKey: string, Slot: number): string
	return `{ItemKey}{ColdKeySuffix}{Slot}`
end

local function Grown(Count: number): number
	return math.min(Count * ReplicaFactor, ReplicasMost)
end

return {
	ReplicaKey = ReplicaKey,
	SlotOf = SlotOf,
	HomeOf = HomeOf,
	ColdKey = ColdKey,
	Grown = Grown,
}
