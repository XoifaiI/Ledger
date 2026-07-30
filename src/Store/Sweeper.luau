--!strict
--!optimize 2

-- retries the keys a failed write left stranded, and tidies transaction markers every tenth pass

local SetInterval = require("../Util/SetInterval")
local Types = require("../Types")

type DataStore = Types.DataStore
type Stranded = { Store: DataStore, Key: string, Tries: number }

local SWEEP_INTERVAL = 60
local SWEEP_LIMIT = 256
local SWEEP_TRIES = 5
local MIN_SWEEP_BUDGET = 8
local MIN_LIST_BUDGET = 2
local REAP_EVERY = 10

local function Affordable(Store: DataStore): boolean
	return Store.Wrapper:Budget(Enum.DataStoreRequestType.GetAsync) >= MIN_SWEEP_BUDGET
		and Store.Wrapper:Budget(Enum.DataStoreRequestType.UpdateAsync) >= MIN_SWEEP_BUDGET
end

local function Listable(Store: DataStore): boolean
	return Store.TxWrapper:Budget(Enum.DataStoreRequestType.ListAsync) >= MIN_LIST_BUDGET
end

local Sweeper = {}
Sweeper.__index = Sweeper

export type Sweeper = setmetatable<{
	Entries: { [string]: Stranded },
	Stores: { DataStore },
	Count: number,
	Passes: number,
	Resume: number,
	Ticker: thread
}, typeof(Sweeper)>

function Sweeper.New(Stores: { DataStore }): Sweeper
	local self = setmetatable({ Entries = {}, Stores = Stores, Count = 0, Passes = 0, Resume = 1, Ticker = nil :: any }, Sweeper)
	self.Ticker = SetInterval(SWEEP_INTERVAL, function()
		self:Pass()
	end)
	return self
end

function Sweeper.Add(self: Sweeper, Store: DataStore, Key: string)
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
	self.Entries[Mark] = nil
	self.Count -= 1
end

function Sweeper.Forget(self: Sweeper, Store: DataStore)
	for Mark, Entry in self.Entries do
		if Entry.Store == Store then
			self:Drop(Mark)
		end
	end
end

function Sweeper.Reap(self: Sweeper)
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
		local Store = self.Stores[At]
		if not Affordable(Store) or not Listable(Store) then
			self.Resume = At
			return
		end
		Store:ReapMarkers()
	end
end

function Sweeper.Pass(self: Sweeper)
	self:Reap()

	local Following: { string } = {}
	for Mark in self.Entries do
		table.insert(Following, Mark)
	end

	for _, Mark in Following do
		local Entry = self.Entries[Mark]
		if Entry == nil then
			continue
		end
		if not Affordable(Entry.Store) then
			return
		end

		Entry.Tries += 1
		local Ok, Clean = pcall(function(): boolean
			return Entry.Store:Resettle(Entry.Key)
		end)
		if (Ok and Clean) or Entry.Tries >= SWEEP_TRIES then
			self:Drop(Mark)
		end
	end
end

function Sweeper.Stop(self: Sweeper)
	task.cancel(self.Ticker)
	table.clear(self.Entries)
	self.Count = 0
end

table.freeze(Sweeper)

return table.freeze({
	New = Sweeper.New
})
