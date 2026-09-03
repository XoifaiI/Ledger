--!strict
--!optimize 2

--[=[

	Sweeper: Retries each key a failed write left unfinished.

	A pass repairs the keys it is following, and drops one once it comes back clean. It gives up on a
	key after a few tries, with a warning naming it. Every tenth pass also reaps transaction markers.
	It checks the request budget before it starts.

	A pass starts after the key the last one reached, so no key waits behind another that never comes
	clean. It skips a key whose lease another server holds. A lease that cannot reach its map ends the
	pass after that one key. A skipped key keeps its tries, since a skip is not a try.

	Return type: A table with New. The type is Sweeper.
	Example usage:
		local Sweeper = require("./Sweeper")
		local Sweep = Sweeper.New()
--]=]

local Clock = require("../Util/Clock")
local Windows = require("../Core/Constants/Windows")
local Transactions = require("../Core/Constants/Transactions")
local SetInterval = require("../Util/SetInterval")
local Types = require("./Types")

type Swept = Types.Swept
type SweeperImpl = Types.SweeperImpl

export type Sweeper = Types.Sweeper

local SWEEP_LIMIT = 256
local SWEEP_TRIES = 5
local MIN_SWEEP_BUDGET = 8
local MIN_LIST_BUDGET = 2
local REAP_EVERY = 10

local function Affordable(Held: Swept): boolean
	return Held.Affords(Enum.DataStoreRequestType.GetAsync, MIN_SWEEP_BUDGET) and Held.Affords(Enum.DataStoreRequestType.UpdateAsync, MIN_SWEEP_BUDGET)
end

local function Listable(Held: Swept): boolean
	return Held.TxAffords(Enum.DataStoreRequestType.ListAsync, MIN_LIST_BUDGET)
end

local Sweeper = {} :: SweeperImpl
Sweeper.__index = Sweeper

function Sweeper.New(): Sweeper
	local Built: Sweeper = setmetatable({ Entries = {}, Stores = {}, Count = 0, Passes = 0, Resume = 1, Cursor = nil, Epoch = 0, Ticker = nil :: any }, Sweeper) :: any
	Built.Ticker = SetInterval(Clock.Held(), Windows.SWEEP, function()
		Built:Pass()
	end)
	return Built
end

function Sweeper.Adopt(self: Sweeper, Held: Swept)
	if table.find(self.Stores, Held) ~= nil then
		return
	end
	table.insert(self.Stores, Held)
end

function Sweeper.Add(self: Sweeper, Held: Swept, Key: string)
	local Mark = Held.Mark(Key)
	if self.Entries[Mark] ~= nil then
		return
	end
	if self.Count >= SWEEP_LIMIT then
		warn(`Ledger: the recovery sweep is already following {SWEEP_LIMIT} keys, so nothing retries '{Key}' on its own. call Resettle on it yourself`)
		return
	end
	self.Entries[Mark] = { Store = Held, Key = Key, Tries = 0 }
	self.Count += 1
end

function Sweeper.Drop(self: Sweeper, Mark: string)
	if self.Entries[Mark] == nil then
		return
	end
	assert(self.Count > 0, "the sweep is dropping a key it is following while its count says it follows none")
	self.Entries[Mark] = nil
	self.Count -= 1
end

function Sweeper.Forget(self: Sweeper, Held: Swept)
	for Mark, Entry in self.Entries do
		if Entry.Store == Held then
			self:Drop(Mark)
		end
	end

	local Listed = table.find(self.Stores, Held)
	if Listed ~= nil then
		table.remove(self.Stores, Listed)
	end
end

function Sweeper.Reap(self: Sweeper, Mine: number?)
	self.Passes += 1
	if self.Passes % REAP_EVERY ~= 0 then
		return
	end

	local Total = #self.Stores
	if Total == 0 then
		return
	end
	if self.Resume > Total then
		self.Resume = 1
	end

	for Step = 0, Total - 1 do
		local At = ((self.Resume + Step - 1) % Total) + 1
		if Mine ~= nil and self.Epoch ~= Mine then
			self.Resume = At
			return
		end

		local Held = self.Stores[At]
		if not Affordable(Held) or not Listable(Held) then
			self.Resume = At
			return
		end
		Held.ReapMarkers(true)
	end
end

function Sweeper.Pass(self: Sweeper)
	local Mine = self.Epoch
	self:Reap(Mine)

	local Following: { string } = {}
	for Mark in self.Entries do
		table.insert(Following, Mark)
	end
	table.sort(Following)

	local Start = 1
	local Cursor = self.Cursor
	if Cursor ~= nil then
		for Index, Mark in Following do
			if Mark > Cursor then
				Start = Index
				break
			end
			Start = Index + 1
		end
	end

	local Degraded = false
	for Step = 0, #Following - 1 do
		local Mark = Following[(Start + Step - 1) % #Following + 1]
		if self.Epoch ~= Mine or Degraded then
			return
		end
		self.Cursor = Mark

		local Entry = self.Entries[Mark]
		if Entry == nil then
			continue
		end
		if not Affordable(Entry.Store) then
			continue
		end

		local Claim = Entry.Store.Claim(Entry.Key, Windows.PASS_LEASE)
		if Claim.Outcome == Transactions.HELD then
			continue
		end
		Degraded = Claim.Outcome == Transactions.UNKNOWN

		local Ok, Clean, Moved = pcall(function(): (boolean, boolean)
			return Entry.Store.Repair(Entry.Key)
		end)
		if Claim.Outcome == Transactions.TAKEN and not Ok then
			Claim.Release()
		end
		if Ok and Clean then
			self:Drop(Mark)
			continue
		end

		Entry.Tries = if Ok and Moved then 0 else Entry.Tries + 1
		if Entry.Tries < SWEEP_TRIES then
			continue
		end

		warn(
			`Ledger: gave up retrying '{Entry.Key}' after {SWEEP_TRIES} goes, so whatever is unfinished on it waits for the next write. call Resettle on it yourself: {if Ok
				then "it still had something pending"
				else tostring(Clean)}`
		)
		self:Drop(Mark)
	end
end

function Sweeper.Stop(self: Sweeper)
	self.Epoch += 1
	Clock.Cancel(self.Ticker)
	table.clear(self.Entries)
	self.Count = 0
end

table.freeze(Sweeper)

return table.freeze({
	New = Sweeper.New,
})
