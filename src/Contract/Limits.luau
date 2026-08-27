--!strict
--!optimize 2

--[=[
	Limits: Every cap Ledger holds itself to, in one place a test can move.

	The defaults are the real ones. A datastore value stops at 4 MB, and the rest are cut from that
	so a record always has room for the op that is about to go on it.
	A margin is a share of the cap it guards rather than a fixed number of bytes, so a smaller cap
	brings its margin down with it and the order they fire in never changes.
	This is the one table in Ledger that is not frozen. A harness that shrinks these reaches the same
	refusals with a hundredth of the data, which is the only reason it can be written to at all. Set
	takes whole bytes and Reset puts the real ones back. Depth counts levels rather than bytes, and
	is the one cap here that neither of them moves, because a value that nests that far is cyclic
	whatever size the rest of the caps are cut to.

	Return type: A table of the caps, with Set and Reset.
	Example usage:
		local Limits = require("../Contract/Limits")
		if Bytes > Limits.State then Refuse() end
--]=]

export type Sizes = {
	read Value: number?,
	read State: number?,
	read Op: number?,
	read Log: number?,
	read Compact: number?,
}

local DEFAULTS: { [string]: number } = {
	Value = 4 * 1024 * 1024,
	State = 2 * 1024 * 1024,
	Op = 1024 * 1024,
	Log = 1536 * 1024,
	Compact = 1024 * 1024,
}

local DEPTH = 64

local VALUE_MARGIN = 8
local STATE_MARGIN = 4
local HELD_MARGIN = 6

local Limits = {
	Value = DEFAULTS.Value,
	State = DEFAULTS.State,
	Op = DEFAULTS.Op,
	Log = DEFAULTS.Log,
	Compact = DEFAULTS.Compact,
	Depth = DEPTH,

	Held = 0,
	StateFloor = 0,
	ValueWarn = 0,
	StateWarn = 0,
}

local Loose = Limits :: { [string]: any }

local function Derive()
	Limits.Held = Limits.Log + Limits.Log // HELD_MARGIN
	Limits.StateFloor = Limits.State - Limits.Op
	Limits.ValueWarn = Limits.Value - Limits.Value // VALUE_MARGIN
	Limits.StateWarn = Limits.State - Limits.State // STATE_MARGIN
end

local function Set(Sizes: Sizes)
	assert(type(Sizes) == "table", "Limits.Set takes a table of byte counts")

	local Given = Sizes :: { [string]: any }
	for Named in DEFAULTS do
		local Held = Given[Named]
		if Held == nil then
			continue
		end

		assert(type(Held) == "number" and Held == Held // 1 and Held > 0, `Limits.{Named} has to be a whole number of bytes above zero`)
		Loose[Named] = Held
	end

	assert(Limits.Op < Limits.State, "an op has to be smaller than the state it goes into, or nothing could ever be written")
	assert(Limits.State <= Limits.Value, "a state cannot be larger than the value it is stored in")
	assert(Limits.Log < Limits.Value, "a log cannot be larger than the value it is stored in")
	Derive()
end

local function Reset()
	for Named, Held in DEFAULTS do
		Loose[Named] = Held
	end
	Derive()
end

Derive()

Limits.Set = Set
Limits.Reset = Reset

return Limits
