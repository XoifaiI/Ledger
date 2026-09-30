--!strict
--!optimize 2

--[=[

	Shown: What this server has shown of each key, so a read never shows an older state.

	The table keeps the largest write count shown for up to Limits.SHOWN_MAX keys. A key it forgets
	sets its bit in a set of Limits.SHOWN_BITS. Allows refuses a view older than the one shown, and a
	view of a forgotten key whose bit is set, which must be read fresh. Show records a view.

	Return type: The Shown class, with New and the methods Allows, Stale and Show.
	Example usage:
		if Table:Allows(Name, View.Writes) then Table:Show(Name, View.Writes) end
--]=]

local Hash = require("../Encode/Hash")
local Limits = require("../Core/Constants/Limits")
local Lru = require("../Util/Lru")

type ShownImpl = {
	__index: ShownImpl,
	New: () -> Shown,
	Allows: (self: Shown, Name: string, Writes: number) -> boolean,
	Stale: (self: Shown, Name: string) -> boolean,
	Show: (self: Shown, Name: string, Writes: number) -> (),
}

type Data = {
	read Seen: Lru.Lru<number>,
	read Bits: buffer,
}

export type Shown = setmetatable<Data, ShownImpl>

local Shown = {} :: ShownImpl
Shown.__index = Shown

local function Bit(Name: string): (number, number)
	local Index = Hash(Name) % Limits.SHOWN_BITS
	return Index // 8, bit32.lshift(1, Index % 8)
end

function Shown.New(): Shown
	local Fresh: Data = { Seen = Lru.New(Limits.SHOWN_MAX), Bits = buffer.create(Limits.SHOWN_BITS // 8) }
	return setmetatable(Fresh, Shown)
end

function Shown.Stale(self: Shown, Name: string): boolean
	if self.Seen:Get(Name) ~= nil then
		return false
	end
	local Byte, Mask = Bit(Name)
	return bit32.btest(buffer.readu8(self.Bits, Byte), Mask)
end

function Shown.Allows(self: Shown, Name: string, Writes: number): boolean
	local Held = self.Seen:Get(Name)
	if Held == nil then
		return not self:Stale(Name)
	end
	return Writes >= Held
end

function Shown.Show(self: Shown, Name: string, Writes: number)
	local Held = self.Seen:Get(Name)
	local Forgot = self.Seen:Put(Name, if Held then math.max(Held, Writes) else Writes)
	if Forgot then
		local Byte, Mask = Bit(Forgot)
		buffer.writeu8(self.Bits, Byte, bit32.bor(buffer.readu8(self.Bits, Byte), Mask))
	end
end

return Shown
