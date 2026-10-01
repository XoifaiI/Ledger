--!strict

--[=[

	Gold: A game for the cases to write, and readers for what a key holds.

	The game holds Gold, and an op adds its Add to it; a debit below 0 is refused. An op's Tag is kept
	and its Bad is written over Gold. Build gives the game's build at Ledger's defaults, with any field
	changed.

	Return type: A table with NOW, Build, DEFAULT, Gold and Record.
	Example usage:
		local Gold = require("./Gold")
		local Using = Gold.Build({ StateCap = 40 })
--]=]

local Book = require("../src/Record/Book")
local Sizes = require("../src/Core/Constants/Sizes")
local Types = require("../src/Record/Types")
local Windows = require("../src/Core/Constants/Windows")

local NOW = 1_000_000

local function Reducer(State: { Gold: number, Tag: string? }, Op: { Add: number, Tag: string?, Bad: any? }): unknown
	if State.Gold + Op.Add < 0 then
		return nil
	end
	local Next = table.clone(State)
	Next.Gold += Op.Add
	if Op.Tag then
		Next.Tag = Op.Tag
	end
	if Op.Bad ~= nil then
		(Next :: any).Gold = Op.Bad
	end
	return Next
end

local function Build(Change: { [string]: any }?): Types.Build
	local Made: { [string]: any } = {
		Reducer = Reducer,
		Migrations = {},
		Default = { Gold = 0 },
		Level = 0,
		Floor = 0,
		Money = { "Gold" },
		Fields = { Gold = true, Tag = true },
		Erasable = false,
		Window = {},
		Minted = Windows.MINTED,
		CutWindow = Windows.CUT,
		TimedRoom = Sizes.TIMED_ROOM,
		UntimedRoom = Sizes.UNTIMED_ROOM,
		WorkRoom = Sizes.WORK_ROOM,
		CutNames = Sizes.CUT_NAMES,
		LossRoom = Sizes.LOSS_ROOM,
		KeepNamed = Windows.KEEP_NAMED,
		LegLimit = math.huge,
		StateCap = Sizes.STATE_CAP,
		Ahead = Windows.AHEAD,
		Hold = Windows.HOLD,
	}
	for Field, Value in Change or {} do
		Made[Field] = Value
	end
	return Made :: any
end

local function Gold(Current: unknown): number
	return ((Current :: any).s :: any).Gold
end

local function Record(Current: unknown): Book.Book
	return Book.Decode((Current :: any).b) :: Book.Book
end

return table.freeze({
	NOW = NOW,
	Build = Build,
	DEFAULT = Build(),
	Gold = Gold,
	Record = Record,
})
