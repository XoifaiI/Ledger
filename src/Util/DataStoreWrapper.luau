--!strict
--!optimize 2

--[=[
    DataStoreWrapper: thin datastore wrapper, a per-key queue keeps requests in order so retries never reorder writes, every call retries with backoff

    Return type: frozen table with a New constructor that returns a DataStoreWrapper
    Example usage:
        local DataStoreWrapper = require("./DataStoreWrapper")
        local Store = DataStoreWrapper.New("PlayerData")
        local Ok, Value = Store:GetAsync("player_1")
--]=]

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
	ListKeysAsync: (
		self: DataStoreWrapper,
		Prefix: string,
		PageSize: number?,
		Cursor: string?,
		ExcludeDeleted: boolean?,
		Handler: Handler?
	) -> (boolean, any),
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
	GetQueueLength: (self: DataStoreWrapper, Key: string) -> number,
	AllQueuesEmpty: (self: DataStoreWrapper) -> boolean,
	SkipAllQueuesToLastEnqueued: (self: DataStoreWrapper) -> (),
}

export type DataStoreWrapper = setmetatable<{
	Name: string,
	Attempts: number?,
	Constant: number?,
	Exponent: number?,
	Queues: { [string]: ThreadQueue },
}, DataStoreWrapperImpl>

local DataStoreWrapper = {} :: DataStoreWrapperImpl
DataStoreWrapper.__index = DataStoreWrapper

local function GetStore(self: DataStoreWrapper): DataStore
	return DataStoreService:GetDataStore(self.Name)
end

local function AttemptAsync(
	self: DataStoreWrapper,
	Key: string,
	Operation: (Store: DataStore) -> ...any,
	Handler: Handler?
): ...any
	return KeyedRetryQueue.Run(self, Key, function()
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

function DataStoreWrapper.ListKeysAsync(
	self: DataStoreWrapper,
	Prefix: string,
	PageSize: number?,
	Cursor: string?,
	ExcludeDeleted: boolean?,
	Handler: Handler?
): (boolean, any)
	return AttemptAsync(self, Prefix, function(Store: DataStore)
		return Store:ListKeysAsync(Prefix, PageSize, Cursor, ExcludeDeleted)
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

function DataStoreWrapper.GetQueueLength(self: DataStoreWrapper, Key: string): number
	return KeyedRetryQueue.GetLength(self, Key)
end

function DataStoreWrapper.AllQueuesEmpty(self: DataStoreWrapper): boolean
	return KeyedRetryQueue.AllEmpty(self)
end

function DataStoreWrapper.SkipAllQueuesToLastEnqueued(self: DataStoreWrapper)
	KeyedRetryQueue.SkipAllToLastEnqueued(self)
end

local function New(Name: string, Attempts: number?, Constant: number?, Exponent: number?): DataStoreWrapper
	return setmetatable({
		Name = Name,
		Attempts = Attempts,
		Constant = Constant,
		Exponent = Exponent,
		Queues = {},
	}, DataStoreWrapper) :: DataStoreWrapper
end

table.freeze(DataStoreWrapper)

return table.freeze({
	New = New,
})
