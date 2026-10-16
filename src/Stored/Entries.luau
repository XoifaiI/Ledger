--!strict
--!optimize 2

--[=[
	Entries: the named entry that a decision of a timed or untimed op writes into T or U.

	Its window is the one the limits give the op's kind, rounded up to whole WindowUnits as the format stores
	it. A kind the store gave no window, as every game kind that sets none, takes the default timed window. It
	stores a sub name's part.

	Return type: A plain table with FingerprintOf, PlainName, WindowOf, NewEntry, NewTimedEntry and
	NewUntimedEntry.
	Example usage:
		local Entry = Entries.NewTimedEntry(Limits, "Buy", Name, Stamp, { Kind = "Took" })
--]=]

local Fates = require("./Items/Fates")
local Format = require("../Encoding/Format")
local Names = require("../Encoding/Names")
local Settable = require("../Constants/Settable")
local Shapes = require("../Shapes")
local Timed = require("./Items/Timed")

type Fate = Fates.Fate
type Name = Names.Name
type OpName = Names.OpName
type GameOpName = Names.GameOpName
type NamedEntry = Timed.NamedEntry
type Limits = Shapes.Limits

local RoundWindow = Format.RoundWindow

local DefaultWindow = Settable.TimedWindow.Default

local function FingerprintOf(Name: OpName): number?
	if Name.Kind == "Game" then
		return Name.Fingerprint
	end
	return nil
end

local function PlainName(Name: OpName): Name
	if Name.Kind == "Game" then
		return { Kind = "Game", Text = Name.Text }
	end
	return { Kind = "Drawn", Server = Name.Server, Counter = Name.Counter }
end

local function NewEntry(Name: OpName, Stamp: number, Fate: Fate, Window: number, WindowUnit: number): NamedEntry
	return {
		Kind = "Named",
		Fate = Fate,
		WindowSeconds = RoundWindow(Window, WindowUnit),
		Name = { Name = PlainName(Name), Part = Name.Part },
		Stamp = Stamp,
		Fingerprint = FingerprintOf(Name),
	}
end

local function WindowOf(Windows: { [string]: number }, OpKind: string): number
	local Window = Windows[OpKind]
	if Window == nil then
		return DefaultWindow
	end
	return Window
end

local function NewTimedEntry(Limits: Limits, OpKind: string, Name: OpName, Stamp: number, Fate: Fate): NamedEntry
	return NewEntry(Name, Stamp, Fate, WindowOf(Limits.TimedWindows, OpKind), Limits.WindowUnit)
end

local function NewUntimedEntry(Limits: Limits, OpKind: string, Name: GameOpName, Clock: number, Fate: Fate): NamedEntry
	return NewEntry(Name, Clock, Fate, WindowOf(Limits.UntimedWindows, OpKind), Limits.WindowUnit)
end

return {
	FingerprintOf = FingerprintOf,
	PlainName = PlainName,
	WindowOf = WindowOf,
	NewEntry = NewEntry,
	NewTimedEntry = NewTimedEntry,
	NewUntimedEntry = NewUntimedEntry,
}
