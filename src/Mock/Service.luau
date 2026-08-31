--!strict
--!optimize 2

--[=[

	Service: The service half of the fake datastore.

	It hands out stores by name and scope, and holds this server's request budget. The budget refills
	against the scheduler's clock, so a run that owns its clock owns the refill too. Conflicts counts
	the writes that met on one key and had to run their transform again.

	Return type: A table with New.
	Example usage:
		local Service = require("./Service")
		local Fake = Service.New({ Players = 20 })
--]=]

local Engine = require("../Util/Engine")
local Roblox = require("../Schedulers/Roblox")

local Datastore = require("../Core/Constants/Datastore")
local Budget = require("./Budget")
local Store = require("./Store")
local Types = require("./Types")

type Service = Types.Service
type Options = Types.Options
type Lane = Types.Lane

local function CheckName(Name: string)
	if type(Name) ~= "string" or #Name == 0 then
		error("Ledger mock: a datastore name must be a non empty string", 0)
	end
	if #Name > Datastore.MAX_NAME then
		error(`Ledger mock: datastore name exceeds the {Datastore.MAX_NAME} character limit`, 0)
	end
end

local Service = {} :: Types.ServiceImpl
Service.__index = Service

function Service.New(Options: Options?, Scheduler: Engine.Scheduler?): Service
	local Config: Options = Options or {}
	local Players = Config.Players or 0
	return setmetatable({
		Scheduler = Scheduler or Roblox.New(),
		Stores = {},
		Tokens = {},
		Filled = {},
		Queued = 0,
		Conflicts = 0,
		Players = Players,
		CCU = Config.CCU or Players,
		Throttled = Config.Throttled ~= false,
	}, Service)
end

function Service.ServerCap(self: Service, Kind: Enum.DataStoreRequestType): number
	return Budget.Ceiling(Budget.Allowance(Kind).Server, self.Players)
end

function Service.LanesFor(self: Service, Kind: Enum.DataStoreRequestType): { Lane }
	local Allowance = Budget.Allowance(Kind)
	return {
		{ Id = `s\0{Kind.Name}`, Cap = Budget.Ceiling(Allowance.Server, self.Players) },
		{ Id = `x\0{Kind.Name}`, Cap = Budget.Ceiling(Allowance.Experience, self.CCU) },
	}
end

function Service.Refill(self: Service, Id: string, Cap: number): number
	local Now = self.Scheduler.Now()
	local Held = math.min(Cap, self.Tokens[Id] or Cap)
	local Since = Now - (self.Filled[Id] or Now)

	Held = math.min(Cap, Held + Since * (Cap / Datastore.REFILL_WINDOW))
	self.Tokens[Id] = Held
	self.Filled[Id] = Now
	return Held
end

function Service.Ready(self: Service, Lanes: { Lane }, Cost: number): boolean
	for _, Lane in Lanes do
		if self:Refill(Lane.Id, Lane.Cap) < Cost then
			return false
		end
	end
	return true
end

function Service.Take(self: Service, Lanes: { Lane }, Cost: number)
	for _, Lane in Lanes do
		self.Tokens[Lane.Id] -= Cost
		assert(self.Tokens[Lane.Id] >= 0, "the mock spent request budget it did not have, so it is more generous than a real server")
	end
end

function Service.Await(self: Service, Lanes: { Lane }, Cost: number)
	if self:Ready(Lanes, Cost) then
		self:Take(Lanes, Cost)
		return
	end

	if self.Queued >= Datastore.QUEUE_LIMIT then
		error(`Ledger mock: {Datastore.THROTTLED}`, 0)
	end

	self.Queued += 1
	while not self:Ready(Lanes, Cost) do
		self.Scheduler.Wait(Datastore.QUEUE_STEP)
	end
	self.Queued -= 1
	assert(self.Queued >= 0, "the mock let more requests off its queue than it ever put on")
	self:Take(Lanes, Cost)
end

function Service.GetRequestBudgetForRequestType(self: Service, Kind: Enum.DataStoreRequestType): number
	return math.floor(self:Refill(`s\0{Kind.Name}`, self:ServerCap(Kind)))
end

function Service.Spend(self: Service, Kind: Enum.DataStoreRequestType)
	if not self.Throttled then
		return
	end
	self:Await(self:LanesFor(Kind), 1)
end

function Service.Carry(self: Service, Way: string, Store: string, Key: string, Bytes: number)
	if not self.Throttled or Bytes <= 0 then
		return
	end

	local Cap = if Way == Datastore.WRITING then Datastore.WRITE_BYTES else Datastore.READ_BYTES
	self:Await({ { Id = `{Way}\0{Store}\0{Key}`, Cap = Cap } }, math.min(Bytes, Cap))
end

function Service.Clear(self: Service)
	table.clear(self.Stores)
	table.clear(self.Tokens)
	table.clear(self.Filled)
	self.Queued = 0
	self.Conflicts = 0
end

function Service.GetDataStore(self: Service, Name: string, Scope: string?): Types.Store
	CheckName(Name)
	if Scope ~= nil and #Scope > Datastore.MAX_SCOPE then
		error(`Ledger mock: scope exceeds the {Datastore.MAX_SCOPE} character limit`, 0)
	end

	local Where = Scope or "global"
	local Id = `{Name}\0{Where}`

	local Found = self.Stores[Id]
	if Found ~= nil then
		return Found
	end

	local Fresh = Store.New(Name, Where, self)
	self.Stores[Id] = Fresh
	return Fresh
end

table.freeze(Service)

return table.freeze({
	New = Service.New,
})
