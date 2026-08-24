--!strict
--!optimize 2

--[=[
	Sweeper: Retries each key that a failed write left unfinished.

	It also removes transaction markers on each tenth pass.
	It stops following a key after a few tries. A key that it cannot repair is a key that something
	else has to hear about.
	A pass that moved something makes progress, even when it is not finished. That pass therefore
	does not count against the tries.
	The walk starts where the last walk stopped, so a store that runs out of budget does not starve
	the stores after it.
	A pass calls the datastore on its own thread. Stop counts up, and a pass gives up between keys once
	that count moves. Stop therefore ends the pass that is running without also stopping a later one.

	Return type: A table with New.
	Example usage:
		local Sweeper = require("./Sweeper")
		local Sweep = Sweeper.New(Stores)
--]=]

local SetInterval = require("../Util/SetInterval")
local Fault = require("../Contract/Fault")
local Types = require("./Types")

type Store = Types.Store
type Stranded = { Store: Store, Key: string, Tries: number }

type SweeperImpl = {
	__index: SweeperImpl,

	New: (Stores: { Store }) -> Sweeper,
	Add: (self: Sweeper, Store: Store, Key: string) -> (),
	Drop: (self: Sweeper, Mark: string) -> (),
	Forget: (self: Sweeper, Store: Store) -> (),
	Reap: (self: Sweeper, Mine: number?) -> (),
	Pass: (self: Sweeper) -> (),
	Stop: (self: Sweeper) -> (),
}

export type Sweeper = setmetatable<{
	Entries: { [string]: Stranded },
	Stores: { Store },
	Count: number,
	Passes: number,
	Resume: number,
	Epoch: number,
	Ticker: thread,
}, SweeperImpl>

local SWEEP_INTERVAL = 60
local SWEEP_LIMIT = 256
local SWEEP_TRIES = 5
local MIN_SWEEP_BUDGET = 8
local MIN_LIST_BUDGET = 2
local REAP_EVERY = 10

local function Affordable(Store: Store): boolean
	return Store.Wrapper:Budget(Enum.DataStoreRequestType.GetAsync) >= MIN_SWEEP_BUDGET and Store.Wrapper:Budget(Enum.DataStoreRequestType.UpdateAsync) >= MIN_SWEEP_BUDGET
end

local function Listable(Store: Store): boolean
	return Store.TxWrapper:Budget(Enum.DataStoreRequestType.ListAsync) >= MIN_LIST_BUDGET
end

local Sweeper = {} :: SweeperImpl
Sweeper.__index = Sweeper

function Sweeper.New(Stores: { Store }): Sweeper
	local Built: Sweeper = setmetatable({ Entries = {}, Stores = Stores, Count = 0, Passes = 0, Resume = 1, Epoch = 0, Ticker = nil :: any }, Sweeper) :: any
	Built.Ticker = SetInterval(SWEEP_INTERVAL, function()
		Built:Pass()
	end)
	return Built
end

function Sweeper.Add(self: Sweeper, Store: Store, Key: string)
	local Mark = Store:Mark(Key)
	if self.Entries[Mark] ~= nil then
		return
	end
	if self.Count >= SWEEP_LIMIT then
		warn(`Ledger: the recovery sweep is already following {SWEEP_LIMIT} keys, so nothing retries '{Key}' on its own. call Resettle on it yourself`)
		return
	end
	self.Entries[Mark] = { Store = Store, Key = Key, Tries = 0 }
	self.Count += 1
end

function Sweeper.Drop(self: Sweeper, Mark: string)
	if self.Entries[Mark] == nil then
		return
	end
	Fault.Holds(self.Count > 0, "the sweep is dropping a key it is following while its count says it follows none")
	self.Entries[Mark] = nil
	self.Count -= 1
end

function Sweeper.Forget(self: Sweeper, Store: Store)
	for Mark, Entry in self.Entries do
		if Entry.Store == Store then
			self:Drop(Mark)
		end
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

		local Store = self.Stores[At]
		if not Affordable(Store) or not Listable(Store) then
			self.Resume = At
			return
		end
		Store:ReapMarkers()
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
			return Entry.Store:Repair(Entry.Key)
		end)
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
	task.cancel(self.Ticker)
	table.clear(self.Entries)
	self.Count = 0
end

table.freeze(Sweeper)

return table.freeze({
	New = Sweeper.New,
})
