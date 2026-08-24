--!strict
--!optimize 2

--[=[
	Budget: The two budget lanes that a real server spends from.

	One lane is this server, and the other is the whole experience. A call must afford both.
	The gauge that a game can read shows the server lane only, which is what the real one shows.
	That gauge therefore reads as more generous than the experience allows.

	Return type: A table with Ceiling, Allowance, the queue limits, READING, WRITING, READ_BYTES and WRITE_BYTES.
	Example usage:
		local Budget = require("./Budget")
		local Cap = Budget.Ceiling(Budget.Allowance(Kind).Server, self.Players)
--]=]

local Types = require("./Types")

type Allowance = Types.Allowance
type Budget = Types.Budget

local REFILL_WINDOW = 60
local QUEUE_LIMIT = 30
local QUEUE_STEP = 0.05

local READ_BYTES = 25 * 1024 * 1024
local WRITE_BYTES = 4 * 1024 * 1024

local READING = "r"
local WRITING = "w"

local THROTTLED = "DataStore request dropped, the queue is full and this server is out of budget"

local STANDARD: Budget = {
	Server = { Base = 60, PerPlayer = 40 },
	Experience = { Base = 300, PerPlayer = 40 },
}
local MUTATING: Budget = {
	Server = { Base = 60, PerPlayer = 40 },
	Experience = { Base = 300, PerPlayer = 20 },
}
local LISTING: Budget = {
	Server = { Base = 5, PerPlayer = 2 },
	Experience = { Base = 300, PerPlayer = 2 },
}

local ALLOWANCES: { [string]: Budget } = {
	GetAsync = STANDARD,
	UpdateAsync = MUTATING,
	SetIncrementAsync = MUTATING,
	GetSortedAsync = STANDARD,
	SetIncrementSortedAsync = MUTATING,
	GetVersionAsync = STANDARD,
	RemoveVersionAsync = STANDARD,
	OnUpdate = STANDARD,
	ListAsync = LISTING,
}

local function Ceiling(Allowance: Allowance, Players: number): number
	return Allowance.Base + Allowance.PerPlayer * Players
end

local function Allowance(Kind: Enum.DataStoreRequestType): Budget
	return ALLOWANCES[Kind.Name] or STANDARD
end

return table.freeze({
	Ceiling = Ceiling,
	Allowance = Allowance,

	REFILL_WINDOW = REFILL_WINDOW,
	QUEUE_LIMIT = QUEUE_LIMIT,
	QUEUE_STEP = QUEUE_STEP,
	THROTTLED = THROTTLED,

	READING = READING,
	WRITING = WRITING,
	READ_BYTES = READ_BYTES,
	WRITE_BYTES = WRITE_BYTES,
})
