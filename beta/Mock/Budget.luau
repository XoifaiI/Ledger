--!strict
--!optimize 2

--[=[
	Budget: The two budget lanes that a real server spends from.
	
	One lane is this server, and the other is the whole experience. A call must afford both.
	The gauge that a game can read shows the server lane only, which is what the real one shows.
	That gauge therefore reads as more generous than the experience allows.
	
	Return type: A table with Await, Refill, ServerCap, LanesFor, READING, WRITING, READ_BYTES and WRITE_BYTES.
	Example usage:
		local Budget = require("./Budget")
		Budget.Await(self, Budget.LanesFor(self, Kind), 1)
--]=]

local Types = require("./Types")

type Allowance = Types.Allowance
type Budget = Types.Budget
type Lane = Types.Lane
type Service = Types.Service

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
	Experience = { Base = 300, PerPlayer = 40 }
}
local MUTATING: Budget = {
	Server = { Base = 60, PerPlayer = 40 },
	Experience = { Base = 300, PerPlayer = 20 }
}
local LISTING: Budget = {
	Server = { Base = 5, PerPlayer = 2 },
	Experience = { Base = 300, PerPlayer = 2 }
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
	ListAsync = LISTING
}

local function Ceiling(Allowance: Allowance, Players: number): number
	return Allowance.Base + Allowance.PerPlayer * Players
end

local function ServerCap(self: Service, Kind: Enum.DataStoreRequestType): number
	return Ceiling((ALLOWANCES[Kind.Name] or STANDARD).Server, self.Players)
end

local function LanesFor(self: Service, Kind: Enum.DataStoreRequestType): { Lane }
	local Budget = ALLOWANCES[Kind.Name] or STANDARD
	return {
		{ Id = `s\0{Kind.Name}`, Cap = Ceiling(Budget.Server, self.Players) },
		{ Id = `x\0{Kind.Name}`, Cap = Ceiling(Budget.Experience, self.CCU) }
	}
end

local function Refill(self: Service, Id: string, Cap: number): number
	local Now = os.clock()
	local Held = math.min(Cap, self.Tokens[Id] or Cap)
	local Since = Now - (self.Filled[Id] or Now)

	Held = math.min(Cap, Held + Since * (Cap / REFILL_WINDOW))
	self.Tokens[Id] = Held
	self.Filled[Id] = Now
	return Held
end

local function Ready(self: Service, Lanes: { Lane }, Cost: number): boolean
	for _, Lane in Lanes do
		if Refill(self, Lane.Id, Lane.Cap) < Cost then
			return false
		end
	end
	return true
end

local function Take(self: Service, Lanes: { Lane }, Cost: number)
	for _, Lane in Lanes do
		self.Tokens[Lane.Id] -= Cost
		assert(self.Tokens[Lane.Id] >= 0, "the mock spent request budget it did not have, so it is more generous than a real server")
	end
end

local function Await(self: Service, Lanes: { Lane }, Cost: number)
	if Ready(self, Lanes, Cost) then
		Take(self, Lanes, Cost)
		return
	end

	if self.Queued >= QUEUE_LIMIT then
		error(`Ledger mock: {THROTTLED}`, 0)
	end

	self.Queued += 1
	while not Ready(self, Lanes, Cost) do
		task.wait(QUEUE_STEP)
	end
	self.Queued -= 1
	assert(self.Queued >= 0, "the mock let more requests off its queue than it ever put on")
	Take(self, Lanes, Cost)
end

return table.freeze({
	Await = Await,
	Refill = Refill,
	ServerCap = ServerCap,
	LanesFor = LanesFor,

	READING = READING,
	WRITING = WRITING,
	READ_BYTES = READ_BYTES,
	WRITE_BYTES = WRITE_BYTES
})
