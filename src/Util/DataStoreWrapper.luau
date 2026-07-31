--!strict
--!optimize 2

-- thin datastore wrapper, a per key queue keeps requests in order and every call retries with backoff

local DataStoreService = game:GetService("DataStoreService")

local NoYield = require("./NoYield")
local ThreadQueue = require("./ThreadQueue")
local KeyedRetryQueue = require("./KeyedRetryQueue")

type ThreadQueue = ThreadQueue.ThreadQueue
type Handler = KeyedRetryQueue.Handler
type Transform = (any, DataStoreKeyInfo) -> ...any

type DataStoreWrapperImpl = {
	__index: DataStoreWrapperImpl,
	GetAsync: (self: DataStoreWrapper, Key: string, Handler: Handler?) -> (boolean, any, DataStoreKeyInfo?),
	UpdateAsync: (self: DataStoreWrapper, Key: string, Transform: Transform, Handler: Handler?) -> (boolean, any, DataStoreKeyInfo?),
	RemoveAsync: (self: DataStoreWrapper, Key: string, Handler: Handler?) -> (boolean, any, DataStoreKeyInfo?),
	ListVersionsAsync: (
		self: DataStoreWrapper,
		Key: string,
		SortDirection: Enum.SortDirection?,
		MinDate: number?,
		MaxDate: number?,
		PageSize: number?,
		Handler: Handler?
	) -> (boolean, any),
	GetVersionAsync: (self: DataStoreWrapper, Key: string, Version: string, Handler: Handler?) -> (boolean, any, DataStoreKeyInfo?),
	ListKeysAsync: (self: DataStoreWrapper, Prefix: string?, PageSize: number?, Handler: Handler?) -> (boolean, any),
	Budget: (self: DataStoreWrapper, Kind: Enum.DataStoreRequestType) -> number,
	SkipAllQueuesToLastEnqueued: (self: DataStoreWrapper) -> ()
}

export type DataStoreWrapper = setmetatable<{
	Name: string,
	Spent: number,
	Attempts: number?,
	Constant: number?,
	Exponent: number?,
	Jitter: number?,
	Direct: boolean?,
	Store: DataStore?,
	Budgets: ((Kind: Enum.DataStoreRequestType) -> number)?,
	Queues: { [string]: ThreadQueue }
}, DataStoreWrapperImpl>

local DataStoreWrapper = {} :: DataStoreWrapperImpl
DataStoreWrapper.__index = DataStoreWrapper

local Backend: ((Name: string) -> any)? = nil
local Budgets: ((Kind: Enum.DataStoreRequestType) -> number)? = nil

local function Use(Named: ((Name: string) -> any)?, Ask: ((Kind: Enum.DataStoreRequestType) -> number)?)
	Backend = Named
	Budgets = Ask
end

local function Swapped(): boolean
	return Backend ~= nil
end

local function GetStore(self: DataStoreWrapper): DataStore
	local Own = self.Store
	if Own ~= nil then
		return Own
	end

	local Named = Backend
	if Named ~= nil then
		return Named(self.Name)
	end
	return DataStoreService:GetDataStore(self.Name)
end

local function AttemptAsync(
	self: DataStoreWrapper,
	Key: string,
	Operation: (Store: DataStore) -> ...any,
	Handler: Handler?
): ...any
	return KeyedRetryQueue.Run(self, Key, function()
		self.Spent += 1
		return Operation(GetStore(self))
	end, Handler)
end

function DataStoreWrapper.GetAsync(self: DataStoreWrapper, Key: string, Handler: Handler?): (boolean, any, DataStoreKeyInfo?)
	return AttemptAsync(self, Key, function(Store: DataStore)
		return Store:GetAsync(Key)
	end, Handler)
end

function DataStoreWrapper.UpdateAsync(
	self: DataStoreWrapper,
	Key: string,
	Transform: Transform,
	Handler: Handler?
): (boolean, any, DataStoreKeyInfo?)
	return AttemptAsync(self, Key, function(Store: DataStore)
		return Store:UpdateAsync(Key, function(Current: any, KeyInfo: DataStoreKeyInfo)
			return NoYield(Transform, Current, KeyInfo)
		end)
	end, Handler)
end

function DataStoreWrapper.RemoveAsync(self: DataStoreWrapper, Key: string, Handler: Handler?): (boolean, any, DataStoreKeyInfo?)
	return AttemptAsync(self, Key, function(Store: DataStore)
		return Store:RemoveAsync(Key)
	end, Handler)
end

function DataStoreWrapper.ListVersionsAsync(
	self: DataStoreWrapper,
	Key: string,
	SortDirection: Enum.SortDirection?,
	MinDate: number?,
	MaxDate: number?,
	PageSize: number?,
	Handler: Handler?
): (boolean, any)
	return AttemptAsync(self, Key, function(Store: DataStore)
		return Store:ListVersionsAsync(Key, SortDirection, MinDate, MaxDate, PageSize)
	end, Handler)
end

function DataStoreWrapper.GetVersionAsync(self: DataStoreWrapper, Key: string, Version: string, Handler: Handler?): (boolean, any, DataStoreKeyInfo?)
	return AttemptAsync(self, Key, function(Store: DataStore)
		return Store:GetVersionAsync(Key, Version)
	end, Handler)
end

function DataStoreWrapper.ListKeysAsync(self: DataStoreWrapper, Prefix: string?, PageSize: number?, Handler: Handler?): (boolean, any)
	return AttemptAsync(self, "", function(Store: DataStore)
		return Store:ListKeysAsync(Prefix or "", PageSize, nil, true)
	end, Handler)
end

function DataStoreWrapper.Budget(self: DataStoreWrapper, Kind: Enum.DataStoreRequestType): number
	local Ask = self.Budgets or Budgets
	if Ask ~= nil then
		return Ask(Kind)
	end
	return DataStoreService:GetRequestBudgetForRequestType(Kind)
end

function DataStoreWrapper.SkipAllQueuesToLastEnqueued(self: DataStoreWrapper)
	KeyedRetryQueue.SkipAllToLastEnqueued(self)
end

local function New(Name: string, Attempts: number?, Constant: number?, Exponent: number?): DataStoreWrapper
	return setmetatable({
		Name = Name,
		Spent = 0,
		Attempts = Attempts,
		Constant = Constant,
		Exponent = Exponent,
		Queues = {}
	}, DataStoreWrapper) :: DataStoreWrapper
end

table.freeze(DataStoreWrapper)

return table.freeze({
	New = New,
	Use = Use,
	Swapped = Swapped
})
