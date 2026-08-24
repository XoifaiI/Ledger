--!strict
--!optimize 2

--[=[
	Say: Says a thing once, and counts every time it happens again.

	A warning names the situation it describes, and the situation is the line it was written on, not
	the words it ends up with. Two of the same warning about different keys read as different text,
	so counting the text would count almost every one of them separately. Counting the line instead
	bounds what a run can hold by how many warnings Ledger has, and not by how long the run went on.
	The first one through says what happened. The rest only add to its count, so a loop that goes
	wrong fills a line of output and not a console.
	Quiet stops the console being written to at all, and keeps counting. A run of many seeds can then
	read what happened afterwards instead of watching it go past.
	Reset starts a fresh set rather than emptying the one it holds, so a run that already took its
	records away still has them after the next run begins.
	Somewhere that cannot say which line called falls back to counting the words instead. That counts
	the same warning about two keys twice, which is worse, but it never loses what one of them said.

	Return type: A table with Warn, Records, Total, Reset, Quiet, IsQuiet and Report. The type is Entry.
	Example usage:
		local Say = require("./Say")
		Say.Warn(`Ledger: could not load '{Key}': {Reason}`)
--]=]

export type Entry = {
	read Says: string,
	read Where: string,
	Count: number,
}

local SELF = 2

local Entries: { [string]: Entry } = {}
local Order: { Entry } = {}
local Counted = 0
local Hushed = false

local function Warn(Message: string, Above: number?)
	Counted += 1

	local Source, Line = debug.info(SELF + (Above or 0), "sl")
	local Where = if Source == nil then Message else `{Source}:{Line}`
	local Held = Entries[Where]
	if Held ~= nil then
		Held.Count += 1
		return
	end

	Entries[Where] = { Says = Message, Where = Where, Count = 1 }
	table.insert(Order, Entries[Where])

	if not Hushed then
		warn(Message)
	end
end

local function Records(): { Entry }
	return Order
end

local function Total(): number
	return Counted
end

local function Reset()
	Entries = {}
	Order = {}
	Counted = 0
end

local function Quiet(On: boolean?)
	Hushed = On ~= false
end

local function IsQuiet(): boolean
	return Hushed
end

local function Report(): string
	if #Order == 0 then
		return "Ledger said nothing"
	end

	local Lines: { string } = {}
	for _, Held in Order do
		table.insert(Lines, `x{Held.Count}\t{Held.Says}\t({Held.Where})`)
	end
	return table.concat(Lines, "\n")
end

return table.freeze({
	Warn = Warn,
	Records = Records,
	Total = Total,
	Reset = Reset,
	Quiet = Quiet,
	IsQuiet = IsQuiet,
	Report = Report,
})
