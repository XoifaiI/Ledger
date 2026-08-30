--!strict
--!optimize 2

--[=[

	Budget: The two budget lanes a real server spends from.

	One lane is this server and the other is the whole experience, and a call has to afford both. The
	gauge a game can read shows the server lane only, which is what the real one shows.

	Return type: A table with Ceiling and Allowance.
	Example usage:
		local Budget = require("./Budget")
		local Cap = Budget.Ceiling(Budget.Allowance(Kind).Server, self.Players)
--]=]

local Types = require("./Types")

type Allowance = Types.Allowance
type Budget = Types.Budget

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
})
