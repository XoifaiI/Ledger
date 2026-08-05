--!strict
--!optimize 2

--[=[
	Service: The service half of the fake datastore.
	
	It hands out stores, and it holds the request budget of this server.
	
	Return type: A table with New and MAX_NAME.
	Example usage:
		local Service = require("./Service")
		local Fake = Service.New({ Players = 20 })
--]=]

local Budget = require("./Budget")
local Store = require("./Store")
local Types = require("./Types")

type Service = Types.Service
type Options = Types.Options

local MAX_NAME = 50
local MAX_SCOPE = 50

local function CheckName(Name: string)
	if type(Name) ~= "string" or #Name == 0 then
		error("Ledger mock: a datastore name must be a non empty string", 0)
	end
	if #Name > MAX_NAME then
		error(`Ledger mock: datastore name exceeds the {MAX_NAME} character limit`, 0)
	end
end

local Service = {} :: Types.ServiceImpl
Service.__index = Service
local function New(Options: Options?): Service
	local Config: Options = Options or {}
	local Players = Config.Players or 0
	return setmetatable({
		Stores = {},
		Tokens = {},
		Filled = {},
		Queued = 0,
		Players = Players,
		CCU = Config.CCU or Players,
		Throttled = Config.Throttled ~= false
	}, Service)
end

function Service.GetRequestBudgetForRequestType(self: Service, Kind: Enum.DataStoreRequestType): number
	return math.floor(Budget.Refill(self, `s\0{Kind.Name}`, Budget.ServerCap(self, Kind)))
end

function Service.Spend(self: Service, Kind: Enum.DataStoreRequestType)
	if not self.Throttled then
		return
	end
	Budget.Await(self, Budget.LanesFor(self, Kind), 1)
end

function Service.Carry(self: Service, Way: string, Store: string, Key: string, Bytes: number)
	if not self.Throttled or Bytes <= 0 then
		return
	end

	local Cap = if Way == Budget.WRITING then Budget.WRITE_BYTES else Budget.READ_BYTES
	Budget.Await(self, { { Id = `{Way}\0{Store}\0{Key}`, Cap = Cap } }, math.min(Bytes, Cap))
end

function Service.Clear(self: Service)
	table.clear(self.Stores)
	table.clear(self.Tokens)
	table.clear(self.Filled)
	self.Queued = 0
end

function Service.GetDataStore(self: Service, Name: string, Scope: string?): Types.Store
	CheckName(Name)
	if Scope ~= nil and #Scope > MAX_SCOPE then
		error(`Ledger mock: scope exceeds the {MAX_SCOPE} character limit`, 0)
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
	New = New,
	MAX_NAME = MAX_NAME
})
