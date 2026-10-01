--!strict
--!optimize 2

--[=[

	Bits: Plumbing. A fixed set of bits, one for each name to hash to.

	Has says whether a name's bit is set, Set sets it, and Clear clears every bit. Two names may hash
	to one bit, so Has may say true for a name never set.

	Return type: The Bits class, with New and the methods Has, Set and Clear.
	Example usage:
		local Forgot = Bits.New(65536)
		Forgot:Set(Name)
--]=]

local Hash = require("../Encode/Hash")

type BitsImpl = {
	__index: BitsImpl,
	New: (Count: number) -> Bits,
	Has: (self: Bits, Name: string) -> boolean,
	Set: (self: Bits, Name: string) -> (),
	Clear: (self: Bits) -> (),
}

type Data = {
	read Count: number,
	read Held: buffer,
}

export type Bits = setmetatable<Data, BitsImpl>

local BYTE = 8

local Bits = {} :: BitsImpl
Bits.__index = Bits

local function Place(Set: Data, Name: string): (number, number)
	local Index = Hash(Name) % Set.Count
	return Index // BYTE, bit32.lshift(1, Index % BYTE)
end

function Bits.New(Count: number): Bits
	if not (Count >= BYTE and Count % BYTE == 0) then
		error(`Bits: the count {Count} is not a whole number of bytes`, 2)
	end
	local Fresh: Data = { Count = Count, Held = buffer.create(Count // BYTE) }
	return setmetatable(Fresh, Bits)
end

function Bits.Has(self: Bits, Name: string): boolean
	local Byte, Mask = Place(self, Name)
	return bit32.btest(buffer.readu8(self.Held, Byte), Mask)
end

function Bits.Set(self: Bits, Name: string)
	local Byte, Mask = Place(self, Name)
	buffer.writeu8(self.Held, Byte, bit32.bor(buffer.readu8(self.Held, Byte), Mask))
end

function Bits.Clear(self: Bits)
	buffer.fill(self.Held, 0, 0)
end

return Bits
