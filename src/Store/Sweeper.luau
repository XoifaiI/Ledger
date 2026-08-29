--!strict
--!optimize 2

--[=[
	Sweeper: Retries each key that a failed write left unfinished.

	It also removes transaction markers on each tenth pass. It stops following a key after a few tries,
	and warns about one it cannot repair. A pass that moved something does not spend a try.
	The walk starts where the last one stopped, so a store out of budget does not starve the rest.
	A store is handed one when it is built and adopts itself into it, so the stores of one server share
	a sweep the way they share a server. Give a store its own and its background work follows how long
	that store has been up. It holds each as five plain functions and never as a store, which keeps
	Store, Fields and Sweeper out of a ring.
	Choosing a scheduler moves its timer rather than replacing it, since a sweep thrown away strands
	every reference already taken to it.

	Return type: A table with New. The type is Sweeper.
	Example usage:
		local Sweep = Sweeper.New()
--]=]

local Warnings = require("../Util/Warnings")
local Clock = require("../Util/Clock")
local Windows = require("../Core/Constants/Windows")
local SetInterval = require("../Util/SetInterval")
local Errors = require("../Core/Errors")
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
	local Built: Sweeper = setmetatable({ Entries = {}, Stores = {}, Count = 0, Passes = 0, Resume = 1, Epoch = 0, Ticker = nil :: any }, Sweeper) :: any
	Built.Ticker = SetInterval(Clock.Held(), Windows.SWEEP, function()
		Built:Pass()
	end)
	return Built
end

function Sweeper.Retime(self: Sweeper)
	Clock.Cancel(self.Ticker)
	self.Ticker = SetInterval(Clock.Held(), Windows.SWEEP, function()
		self:Pass()
	end)
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
		Warnings.Warn(`Ledger: the recovery sweep is already following {SWEEP_LIMIT} keys, so nothing retries '{Key}' on its own. call Resettle on it yourself`)
		return
	end
	self.Entries[Mark] = { Store = Held, Key = Key, Tries = 0 }
	self.Count += 1
end

function Sweeper.Drop(self: Sweeper, Mark: string)
	if self.Entries[Mark] == nil then
		return
	end
	Errors.Holds(self.Count > 0, "the sweep is dropping a key it is following while its count says it follows none")
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
		Held.ReapMarkers()
	end
end

function Sweeper.Pass(self: Sweeper)
	local Mine = self.Epoch
	self:Reap(Mine)

	local Following: { string } = {}
	for Mark in self.Entries do
		table.insert(Following, Mark)
	end

	for _, Mark in Following do
		if self.Epoch ~= Mine then
			return
		end

		local Entry = self.Entries[Mark]
		if Entry == nil then
			continue
		end
		if not Affordable(Entry.Store) then
			continue
		end

		local Ok, Clean, Moved = pcall(function(): (boolean, boolean)
			return Entry.Store.Repair(Entry.Key)
		end)
		if Ok and Clean then
			self:Drop(Mark)
			continue
		end

		Entry.Tries = if Ok and Moved then 0 else Entry.Tries + 1
		if Entry.Tries < SWEEP_TRIES then
			continue
		end

		Warnings.Warn(
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
