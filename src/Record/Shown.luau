--!strict
--!optimize 2

--[=[
	Shown: Object. What this server has shown of each key, so a read never shows an older state.

	Spec: record 5.3.

	The table keeps the largest write count shown for up to Limits.SHOWN_MAX keys. A key it forgets
	sets a bit in a set of SHOWN_BITS, and a view of a key whose bit is set must come from a fresh
	read. Two names may share a bit, so a key never shown may also need a fresh read. A pinned key is
	never forgotten, which an open session on it needs.

	Return type: The Shown class.
	Example usage:
		if Table:Allows(Name, View.Writes) then Table:Show(Name, View.Writes) end
--]=]

local Bits = require("../Util/Bits")
local Limits = require("../Core/Constants/Limits")
local Lru = require("../Util/Lru")

type ShownImpl = {
	__index: ShownImpl,
	New: () -> Shown,
	Allows: (self: Shown, Name: string, Writes: number) -> boolean,
	Stale: (self: Shown, Name: string) -> boolean,
	Show: (self: Shown, Name: string, Writes: number) -> (),
	Pin: (self: Shown, Name: string, Writes: number) -> (),
	Unpin: (self: Shown, Name: string) -> (),
}

type Data = {
	read Seen: Lru.Lru<number>,
	read Pinned: { [string]: number },
	read Forgot: Bits.Bits,
}

export type Shown = setmetatable<Data, ShownImpl>

local SHOWN_BITS = 65536

local Shown = {} :: ShownImpl
Shown.__index = Shown

function Shown.New(): Shown
	local Fresh: Data = { Seen = Lru.New(Limits.SHOWN_MAX), Pinned = {}, Forgot = Bits.New(SHOWN_BITS) }
	return setmetatable(Fresh, Shown)
end

function Shown.Stale(self: Shown, Name: string): boolean
	if self.Pinned[Name] or self.Seen:Get(Name) ~= nil then
		return false
	end
	return self.Forgot:Has(Name)
end

function Shown.Allows(self: Shown, Name: string, Writes: number): boolean
	local Held = self.Pinned[Name] or self.Seen:Get(Name)
	if Held == nil then
		return not self:Stale(Name)
	end
	return Writes >= Held
end

function Shown.Show(self: Shown, Name: string, Writes: number)
	local Pinned = self.Pinned[Name]
	if Pinned then
		self.Pinned[Name] = math.max(Pinned, Writes)
		return
	end
	local Held = self.Seen:Get(Name)
	local Forgot = self.Seen:Put(Name, if Held then math.max(Held, Writes) else Writes)
	if Forgot then
		self.Forgot:Set(Forgot)
	end
end

function Shown.Pin(self: Shown, Name: string, Writes: number)
	self.Pinned[Name] = math.max(self.Pinned[Name] or 0, self.Seen:Get(Name) or 0, Writes)
end

function Shown.Unpin(self: Shown, Name: string)
	local Pinned = self.Pinned[Name]
	if Pinned then
		self.Pinned[Name] = nil
		self:Show(Name, Pinned)
	end
end

return Shown
