--!strict
--!optimize 2

--[=[

	Sizes: Every byte cap Ledger holds itself to.

	The defaults are the real ones, cut from the 4 MB a datastore value stops at. Set replaces them
	and Reset puts them back, so a test can reach the same refusals with less data. Each margin is
	derived from the cap it guards.

	Return type: A table of the caps, with Set and Reset.
	Example usage:
		local Sizes = require("./Sizes")
		if Bytes > Sizes.State then Refuse() end
--]=]

export type Sizes = {
	read Value: number?,
	read State: number?,
	read Op: number?,
	read Log: number?,
	read Compact: number?,
	read Booked: number?,
}

local DEFAULTS: { [string]: number } = {
	Value = 4 * 1024 * 1024,
	State = 2 * 1024 * 1024,
	Op = 1024 * 1024,
	Log = 1536 * 1024,
	Compact = 1024 * 1024,
	Booked = 256,
}

local DEPTH = 64

local VALUE_WARN_AT = 8
local STATE_WARN_AT = 4
local HELD_ROOM = 6

local Sizes = {
	Value = DEFAULTS.Value,
	State = DEFAULTS.State,
	Op = DEFAULTS.Op,
	Log = DEFAULTS.Log,
	Compact = DEFAULTS.Compact,
	Booked = DEFAULTS.Booked,
	Depth = DEPTH,

	Held = 0,
	StateFloor = 0,
	ValueWarn = 0,
	StateWarn = 0,
}

local Loose = Sizes :: { [string]: any }

local function Derive()
	Sizes.Held = Sizes.Log + Sizes.Log // HELD_ROOM
	Sizes.StateFloor = Sizes.State - Sizes.Op
	Sizes.ValueWarn = Sizes.Value - Sizes.Value // VALUE_WARN_AT
	Sizes.StateWarn = Sizes.State - Sizes.State // STATE_WARN_AT
end

local function Set(Given: Sizes)
	assert(type(Given) == "table", "Sizes.Set takes a table of byte counts")

	local Asked = Given :: { [string]: any }
	for Named in DEFAULTS do
		local Held = Asked[Named]
		if Held == nil then
			continue
		end

		assert(type(Held) == "number" and Held == Held // 1 and Held > 0, `Sizes.{Named} has to be a whole number above zero`)
		Loose[Named] = Held
	end

	assert(Sizes.Op < Sizes.State, "an op has to be smaller than the state it goes into, or nothing could ever be written")
	assert(Sizes.State <= Sizes.Value, "a state cannot be larger than the value it is stored in")
	assert(Sizes.Log < Sizes.Value, "a log cannot be larger than the value it is stored in")
	Derive()
end

local function Reset()
	for Named, Held in DEFAULTS do
		Loose[Named] = Held
	end
	Derive()
end

Derive()

Sizes.Set = Set
Sizes.Reset = Reset

return Sizes
