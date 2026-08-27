--!strict
--!optimize 2

--[=[
	Say: Writes each different warning one time. Counts the repeats.

	Warn finds the line that calls it. That line is the key. Warn keeps the first message. For each
	warning from the same line, Warn increases the count. A run therefore holds no more records than
	Ledger has warning lines.
	Warn must read the stack itself. The optimizer can remove a helper function and change the level.
	If Warn cannot find the line, it uses the message as the key.
	Quiet stops the output. Warn continues to count.
	Reset makes a new set of records. A caller that holds the old records keeps them.

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
