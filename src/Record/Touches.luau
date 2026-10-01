--!strict
--!optimize 2

--[=[

	Touches: Logic. When a server that sees an item left on a key may end it.

	Spec: transaction 5.1; cuts 3.3.

	A server's level for an item is the count of leading zero bits of the hash of the item's name.
	The hash is seeded with the server's number, and the level is at most Limits.LEVELS. Due says
	whether the server may act now. The item is past its age: Windows.SETTLE for a mark and
	Windows.PINNED for a pinned record. It is also past Windows.SETTLE and one Windows.STEP for each
	level below the top, and this server first saw it at least those steps ago. So about one and a
	half servers act on one item, however many see it. Gated says the same of a cut's gate, which is
	past its age once it is Windows.SETTLE old. Clear says whether a work room holds no item stamped
	before a given time.

	Return type: A table with Level, Due, Gated and Clear.
	Example usage:
		if Touches.Due(Item, Touches.Level(Server, Name), Now, Seen) then Run(Item) end
--]=]

local Book = require("../Record/Book")
local Hash = require("../Encode/Hash")
local Limits = require("../Core/Constants/Limits")
local Windows = require("../Core/Constants/Windows")

local Touches = {}

function Touches.Level(Server: number, Name: string): number
	return math.min(bit32.countlz(Hash(Name, Server)), Limits.LEVELS)
end

local function Ready(Stamp: number, Age: number, Level: number, Now: number, Seen: number): boolean
	local Wait = (Limits.LEVELS - Level) * Windows.STEP
	return Now - Stamp >= math.max(Age, Windows.SETTLE + Wait) and Now - Seen >= Wait
end

function Touches.Due(Item: Book.Work, Level: number, Now: number, Seen: number): boolean
	return Ready(Item.Stamp, if Item.Form == "Pinned" then Windows.PINNED else Windows.SETTLE, Level, Now, Seen)
end

function Touches.Gated(Gate: Book.Gate, Level: number, Now: number, Seen: number): boolean
	return Ready(Gate.At, Windows.SETTLE, Level, Now, Seen)
end

function Touches.Clear(Work: { [string]: Book.Work }, Since: number): boolean
	for _, Item in Work do
		if Item.Stamp < Since then
			return false
		end
	end
	return true
end

return Touches
