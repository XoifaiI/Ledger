--!strict
--!optimize 2

--[=[

	DataStoreWrapper: Calls a datastore, and calls again when a call fails.

	Each key has its own queue, so writes to one key stay in order. It is handed the scheduler its
	retries wait on and the hook its calls go to, and carries both for everything underneath it.

	Return type: A table with New.
	Example usage:
		local Wrapper = require("./DataStoreWrapper")
		local Books = Wrapper.New("Players", Scheduler, Hook)
		local Ok, Value = Books:GetAsync("1")
--]=]

local Engine = require("./Engine")

local NoYield = require("./NoYield")
local ThreadQueue = require("./ThreadQueue")
local KeyedRetryQueue = require("./KeyedRetryQueue")

type ThreadQueue = ThreadQueue.ThreadQueue
type Handler = KeyedRetryQueue.Handler
type Transform = (any, DataStoreKeyInfo) -> ...any

type DataStoreWrapperImpl = {
	__index: DataStoreWrapperImpl,
	New: (Name: string, Scheduler: Engine.Scheduler, Hook: Engine.Hook, Attempts: number?, Constant: number?, Exponent: number?) -> DataStoreWrapper,
	GetStore: (self: DataStoreWrapper) -> Engine.Store,
	AttemptAsync: (self: DataStoreWrapper, Key: string, Operation: (Store: Engine.Store) -> ...any, Handler: Handler?) -> ...any,
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
	ListKeysAsync: (self: DataStoreWrapper, Prefix: string?, PageSize: number?, Cursor: string?, Handler: Handler?) -> (boolean, any),
	Budget: (self: DataStoreWrapper, Kind: Enum.DataStoreRequestType) -> number,
	SkipAllQueuesToLastEnqueued: (self: DataStoreWrapper) -> (),
}

export type DataStoreWrapper = setmetatable<{
	Name: string,
	Scheduler: Engine.Scheduler,
	Hook: Engine.Hook,
	Spent: number,
	Attempts: number?,
	Constant: number?,
	Exponent: number?,
	Jitter: number?,
	Direct: boolean?,
	Store: Engine.Store?,
	Budgets: ((Kind: Enum.DataStoreRequestType) -> number)?,
	Queues: { [string]: ThreadQueue },
}, DataStoreWrapperImpl>

local DataStoreWrapper = {} :: DataStoreWrapperImpl
DataStoreWrapper.__index = DataStoreWrapper

function DataStoreWrapper.New(Name: string, Scheduler: Engine.Scheduler, Hook: Engine.Hook, Attempts: number?, Constant: number?, Exponent: number?): DataStoreWrapper
	return setmetatable({
		Name = Name,
		Scheduler = Scheduler,
		Hook = Hook,
		Spent = 0,
		Attempts = Attempts,
		Constant = Constant,
		Exponent = Exponent,
		Queues = {},
	}, DataStoreWrapper) :: DataStoreWrapper
end

function DataStoreWrapper.GetStore(self: DataStoreWrapper): Engine.Store
	local Own = self.Store
	if Own ~= nil then
		return Own
	end
	return self.Hook.Open(self.Name)
end

function DataStoreWrapper.AttemptAsync(self: DataStoreWrapper, Key: string, Operation: (Store: Engine.Store) -> ...any, Handler: Handler?): ...any
	assert(type(Key) == "string", "a datastore call was queued under something that is not a key")
	return KeyedRetryQueue.Run(self, Key, function()
		self.Spent += 1
		return Operation(self:GetStore())
	end, Handler)
end

function DataStoreWrapper.GetAsync(self: DataStoreWrapper, Key: string, Handler: Handler?): (boolean, any, DataStoreKeyInfo?)
	return self:AttemptAsync(Key, function(Store: Engine.Store)
		return Store:GetAsync(Key)
	end, Handler)
end

function DataStoreWrapper.UpdateAsync(self: DataStoreWrapper, Key: string, Transform: Transform, Handler: Handler?): (boolean, any, DataStoreKeyInfo?)
	return self:AttemptAsync(Key, function(Store: Engine.Store)
		return Store:UpdateAsync(Key, function(Current: any, KeyInfo: DataStoreKeyInfo)
			return NoYield.Run(Transform, Current, KeyInfo)
		end)
	end, Handler)
end

function DataStoreWrapper.RemoveAsync(self: DataStoreWrapper, Key: string, Handler: Handler?): (boolean, any, DataStoreKeyInfo?)
	return self:AttemptAsync(Key, function(Store: Engine.Store)
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
	return self:AttemptAsync(Key, function(Store: Engine.Store)
		return Store:ListVersionsAsync(Key, SortDirection, MinDate, MaxDate, PageSize)
	end, Handler)
end

function DataStoreWrapper.GetVersionAsync(self: DataStoreWrapper, Key: string, Version: string, Handler: Handler?): (boolean, any, DataStoreKeyInfo?)
	return self:AttemptAsync(Key, function(Store: Engine.Store)
		return Store:GetVersionAsync(Key, Version)
	end, Handler)
end

function DataStoreWrapper.ListKeysAsync(self: DataStoreWrapper, Prefix: string?, PageSize: number?, Cursor: string?, Handler: Handler?): (boolean, any)
	return self:AttemptAsync("", function(Store: Engine.Store)
		return Store:ListKeysAsync(Prefix or "", PageSize, Cursor, true)
	end, Handler)
end

function DataStoreWrapper.Budget(self: DataStoreWrapper, Kind: Enum.DataStoreRequestType): number
	local Ask = self.Budgets
	local Left = if Ask ~= nil then Ask(Kind) else self.Hook.Budget(Kind)
	assert(type(Left) == "number" and Left >= 0, `the request budget for {Kind.Name} came back as something other than a count`)
	return Left
end

function DataStoreWrapper.SkipAllQueuesToLastEnqueued(self: DataStoreWrapper)
	KeyedRetryQueue.SkipAllToLastEnqueued(self)
end

table.freeze(DataStoreWrapper)

return table.freeze({
	New = DataStoreWrapper.New,
})
