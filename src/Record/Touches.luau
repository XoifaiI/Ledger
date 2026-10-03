--!strict
--!optimize 2

--[=[
	Touches: Logic. When a server that sees an item left on a key may end it.

	A server's level for an item is the count of leading zero bits of the hash of the item's name,
	seeded with the server's number, and at most LEVELS. A server may act once the item is past its
	age: Windows.SETTLE for a mark or a gate, and PINNED for a pinned record. The item must also be
	past Windows.SETTLE and one STEP for each level below the top, and this server must have first
	seen it at least those steps ago. So about one and a half servers act on one item, however many
	see it.

	Return type: The Touches module.
	Example usage:
		if Touches.Due(Item, Touches.Level(Server, Name), Now, Seen) then Run(Item) end
--]=]

local Book = require("../Record/Book")
local Hash = require("../Encode/Hash")
local Windows = require("../Core/Constants/Windows")

local WorkForm = Book.WorkForm

local LEVELS = 16
local STEP = Windows.LAG + 2 * Windows.SIGMA + 3 * Windows.DELAY
local PINNED = Windows.ANSWER + 2 * Windows.SIGMA

local Touches = { LEVELS = LEVELS, STEP = STEP, PINNED = PINNED }

function Touches.Level(Server: number, Name: string): number
	return math.min(bit32.countlz(Hash(Name, Server)), LEVELS)
end

local function Ready(Stamp: number, Age: number, Level: number, Now: number, Seen: number): boolean
	local Wait = (LEVELS - Level) * STEP
	return Now - Stamp >= math.max(Age, Windows.SETTLE + Wait) and Now - Seen >= Wait
end

function Touches.Due(Item: Book.Work, Level: number, Now: number, Seen: number): boolean
	return Ready(Item.Stamp, if Item.Form == WorkForm.Pinned then PINNED else Windows.SETTLE, Level, Now, Seen)
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
