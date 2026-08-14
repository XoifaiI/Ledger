--!strict
--!optimize 2

--[=[
	Catalogue: Every operation that Ledger offers, in one table.

	The workload picks from it, the coverage buckets come from it, and it is the list to compare
	against the public surface when that surface grows. Each entry names the reasons that call can
	answer, which is the second half of the coverage table.

	Return type: A table with CATALOGUE, Find, Applicable, Weights and Buckets.
	Example usage:
		local Held = Catalogue.Applicable("Player", true)
--]=]

local Swarm = require("./Swarm")

export type Reason =
	"Refused" | "Busy" | "Spent" | "Unresolved" | "Closed" | "Backlog" | "Full" | "Invalid" | "Behind" | "Held"

export type Keys = "Player" | "String"

export type Family = "Session" | "Read" | "Write" | "Booking" | "Tally" | "Transaction" | "Recovery" | "Removal"

export type Operation = {
	read Name: string,
	read Family: Family,
	read Needs: Keys?,
	read Balance: boolean,
	read Mutates: boolean,
	read Reasons: { Reason },
	read Least: number,
	read Most: number
}

local READS: { Reason } = { "Unresolved", "Behind", "Closed" }

local WRITES: { Reason } = { "Refused", "Unresolved", "Behind", "Full", "Closed" }

local CATALOGUE: { Operation } = {
	{ Name = "Load", Family = "Session", Needs = "Player", Balance = false, Mutates = true, Reasons = { "Behind", "Closed", "Unresolved" }, Least = 1, Most = 20 },
	{ Name = "Unload", Family = "Session", Needs = "Player", Balance = false, Mutates = true, Reasons = {}, Least = 1, Most = 20 },
	{ Name = "WaitForLoaded", Family = "Session", Needs = "Player", Balance = false, Mutates = false, Reasons = {}, Least = 1, Most = 5 },
	{ Name = "Read", Family = "Session", Needs = "Player", Balance = false, Mutates = false, Reasons = {}, Least = 1, Most = 10 },
	{ Name = "Apply", Family = "Session", Needs = nil, Balance = false, Mutates = true, Reasons = { "Refused", "Backlog", "Invalid", "Closed", "Busy", "Unresolved", "Full" }, Least = 1, Most = 100 },
	{ Name = "Commit", Family = "Session", Needs = nil, Balance = false, Mutates = true, Reasons = { "Refused", "Invalid", "Unresolved", "Closed", "Busy", "Full", "Backlog" }, Least = 1, Most = 40 },
	{ Name = "CommitOp", Family = "Session", Needs = nil, Balance = false, Mutates = true, Reasons = { "Refused", "Invalid", "Unresolved", "Closed", "Busy", "Full", "Backlog" }, Least = 1, Most = 20 },
	{ Name = "Flush", Family = "Session", Needs = nil, Balance = false, Mutates = true, Reasons = { "Refused", "Behind", "Unresolved", "Closed", "Full" }, Least = 1, Most = 20 },
	{ Name = "SessionCompact", Family = "Session", Needs = nil, Balance = false, Mutates = true, Reasons = { "Unresolved", "Behind", "Closed", "Full" }, Least = 1, Most = 10 },
	{ Name = "SessionRelease", Family = "Session", Needs = nil, Balance = false, Mutates = true, Reasons = { "Refused", "Unresolved", "Closed", "Full" }, Least = 1, Most = 20 },
	{ Name = "Observe", Family = "Session", Needs = nil, Balance = false, Mutates = false, Reasons = {}, Least = 1, Most = 5 },
	{ Name = "SessionDidApply", Family = "Session", Needs = nil, Balance = false, Mutates = false, Reasons = {}, Least = 1, Most = 10 },

	{ Name = "Peek", Family = "Read", Needs = nil, Balance = false, Mutates = false, Reasons = READS, Least = 1, Most = 30 },
	{ Name = "Inspect", Family = "Read", Needs = nil, Balance = false, Mutates = false, Reasons = { "Unresolved", "Closed" }, Least = 1, Most = 10 },
	{ Name = "DidApply", Family = "Read", Needs = nil, Balance = false, Mutates = false, Reasons = READS, Least = 1, Most = 20 },
	{ Name = "History", Family = "Read", Needs = nil, Balance = false, Mutates = false, Reasons = { "Unresolved", "Closed" }, Least = 1, Most = 10 },
	{ Name = "PeekVersion", Family = "Read", Needs = nil, Balance = false, Mutates = false, Reasons = READS, Least = 1, Most = 10 },

	{ Name = "Edit", Family = "Write", Needs = nil, Balance = false, Mutates = true, Reasons = { "Refused", "Invalid", "Unresolved", "Behind", "Full", "Closed" }, Least = 1, Most = 100 },
	{ Name = "Transfer", Family = "Write", Needs = nil, Balance = true, Mutates = true, Reasons = { "Refused", "Busy", "Spent", "Held", "Unresolved", "Closed" }, Least = 1, Most = 60 },

	{ Name = "Reserve", Family = "Booking", Needs = nil, Balance = false, Mutates = true, Reasons = WRITES, Least = 1, Most = 40 },
	{ Name = "Confirm", Family = "Booking", Needs = nil, Balance = false, Mutates = true, Reasons = WRITES, Least = 1, Most = 30 },
	{ Name = "Release", Family = "Booking", Needs = nil, Balance = false, Mutates = true, Reasons = { "Refused", "Unresolved", "Behind", "Full", "Closed", "Held" }, Least = 1, Most = 30 },
	{ Name = "Grant", Family = "Booking", Needs = nil, Balance = false, Mutates = true, Reasons = { "Refused", "Spent", "Held", "Unresolved" }, Least = 1, Most = 30 },

	{ Name = "Bump", Family = "Tally", Needs = "String", Balance = false, Mutates = true, Reasons = { "Unresolved", "Behind", "Closed" }, Least = 1, Most = 30 },
	{ Name = "Total", Family = "Tally", Needs = "String", Balance = false, Mutates = false, Reasons = READS, Least = 1, Most = 15 },

	{ Name = "Tx", Family = "Transaction", Needs = nil, Balance = false, Mutates = true, Reasons = { "Refused", "Busy", "Spent", "Full", "Invalid", "Unresolved" }, Least = 1, Most = 50 },

	{ Name = "Resettle", Family = "Recovery", Needs = nil, Balance = false, Mutates = true, Reasons = { "Busy", "Unresolved", "Behind", "Closed" }, Least = 1, Most = 15 },
	{ Name = "RecoverTransfers", Family = "Recovery", Needs = nil, Balance = true, Mutates = true, Reasons = { "Busy", "Unresolved", "Behind", "Closed" }, Least = 1, Most = 15 },
	{ Name = "ClearDelivered", Family = "Recovery", Needs = nil, Balance = false, Mutates = true, Reasons = READS, Least = 1, Most = 10 },
	{ Name = "Sweep", Family = "Recovery", Needs = nil, Balance = false, Mutates = true, Reasons = {}, Least = 1, Most = 15 },
	{ Name = "CloseAll", Family = "Recovery", Needs = nil, Balance = false, Mutates = true, Reasons = {}, Least = 1, Most = 1 },

	{ Name = "Reset", Family = "Removal", Needs = nil, Balance = false, Mutates = true, Reasons = { "Refused", "Behind", "Busy", "Unresolved", "Full", "Closed" }, Least = 1, Most = 6 },
	{ Name = "Erase", Family = "Removal", Needs = nil, Balance = false, Mutates = true, Reasons = { "Unresolved", "Behind", "Closed", "Busy" }, Least = 1, Most = 6 },
	{ Name = "Destroy", Family = "Removal", Needs = nil, Balance = false, Mutates = true, Reasons = {}, Least = 1, Most = 3 }
}

local function Find(Name: string): Operation
	for _, Held in CATALOGUE do
		if Held.Name == Name then
			return Held
		end
	end
	error(`no operation named '{Name}' is in the catalogue`, 0)
end

local function Applicable(Keys: Keys, Balance: boolean): { Operation }
	local Held: { Operation } = {}
	for _, Operation in CATALOGUE do
		if Operation.Needs ~= nil and Operation.Needs ~= Keys then
			continue
		end
		if Operation.Balance and not Balance then
			continue
		end
		table.insert(Held, Operation)
	end
	return Held
end

local function Weights(Rng: Random, Held: { Operation }): Swarm.Weighted
	local Names: { string } = table.create(#Held) :: { string }
	for Index, Operation in Held do
		Names[Index] = Operation.Name
	end

	local Drawn = Swarm.Weights(Rng, Names)
	for Index, Weight in Drawn do
		if Weight.Weight == 0 then
			continue
		end
		local Operation = Held[Index]
		Drawn[Index] = { Name = Weight.Name, Weight = Rng:NextInteger(Operation.Least, Operation.Most) }
	end
	return Drawn
end

local function Buckets(): { string }
	local Held: { string } = {}
	for _, Operation in CATALOGUE do
		table.insert(Held, `{Operation.Name}:Ok`)
		for _, Reason in Operation.Reasons do
			table.insert(Held, `{Operation.Name}:{Reason}`)
		end
	end
	return Held
end

return table.freeze({
	CATALOGUE = CATALOGUE,
	Find = Find,
	Applicable = Applicable,
	Weights = Weights,
	Buckets = Buckets
})
