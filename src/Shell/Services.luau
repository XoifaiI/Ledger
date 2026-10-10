--!strict
--!optimize 2

--[=[
	Services: the DataStore, MemoryStore and JSON calls, one request in, one Result out, through ResultOf's one
	pcall. A failed request keeps its error's leading code; a failed Get is throttled when this server's GetAsync
	budget is below 1, other throttles failing plainly. A listing takes 50 keys a page, deleted ones left out.
	Server-only services are got at first use.

	Return type: A plain table with one function per call, and the Result, KeysResult and Transform types.
	Example usage:
		local Result = Services.Get({ Store = "Players", Scope = "global", Key = "Alice" })
		if Result.Kind == "Err" and Result.IsThrottled then ... end
--]=]

local GetOrMake = require("../GetOrMake").GetOrMake
local Names = require("../Encoding/Names")

type StoreKey = Names.StoreKey

export type Result =
	{ read Kind: "Ok", read Value: unknown }
	| { read Kind: "Absent" }
	| { read Kind: "Err", read IsThrottled: boolean, read Code: number? }

export type KeysPage = {
	read Pages: DataStoreKeyPages,
	read Names: { string },
	read IsLast: boolean,
}

export type KeysResult = { read Kind: "Ok", read Page: KeysPage } | { read Kind: "Err" }

export type Transform = (Current: unknown) -> (unknown, { number }?)

export type MemoryTransform = (Current: unknown) -> unknown

local HttpService = game:GetService("HttpService")

local ErrorCodePattern = "^(%d+):"
local KeysPageSize = 50
local AnyKeyPrefix = ""
local ExcludeDeleted = true

local DataStores: { [string]: { [string]: DataStore } } = {}
local Maps: { [string]: MemoryStoreHashMap } = {}

local function NewUncachedGet(): DataStoreGetOptions
	local Options = Instance.new("DataStoreGetOptions")
	Options.UseCache = false
	return Options
end

local Uncached: DataStoreGetOptions? = nil

local function NoScopes(): { [string]: DataStore }
	return {}
end

local function UncachedGet(): DataStoreGetOptions
	local Kept = Uncached
	if Kept ~= nil then
		return Kept
	end
	local Made = NewUncachedGet()
	Uncached = Made
	return Made
end

local function GetDataStoreService(): DataStoreService
	return game:GetService("DataStoreService")
end

local function DataStoreOf(Store: string, Scope: string): DataStore
	local Scopes = GetOrMake(DataStores, Store, NoScopes)
	return GetOrMake(Scopes, Scope, function(): DataStore
		return GetDataStoreService():GetDataStore(Store, Scope)
	end)
end

local function MapOf(Name: string): MemoryStoreHashMap
	return GetOrMake(Maps, Name, function(): MemoryStoreHashMap
		return game:GetService("MemoryStoreService"):GetHashMap(Name)
	end)
end

local function CodeOf(Problem: unknown): number?
	if type(Problem) ~= "string" then
		return nil
	end
	local Digits: string? = string.match(Problem, ErrorCodePattern)
	if Digits == nil then
		return nil
	end
	return tonumber(Digits)
end

local function ResultOf(Body: () -> unknown): Result
	local IsReturned, Answer = pcall(Body)
	if not IsReturned then
		return { Kind = "Err", IsThrottled = false, Code = CodeOf(Answer) }
	end
	if Answer == nil then
		return { Kind = "Absent" }
	end
	return { Kind = "Ok", Value = Answer }
end

local function ReadGetBudget(): unknown
	return GetDataStoreService():GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync)
end

local function IsGetBudgetSpent(): boolean
	local Budget = ResultOf(ReadGetBudget)
	if Budget.Kind ~= "Ok" then
		return false
	end
	local Left = Budget.Value
	if type(Left) ~= "number" then
		return false
	end
	return Left < 1
end

local function ReadGetThrottle(Result: Result): Result
	if Result.Kind ~= "Err" then
		return Result
	end
	return { Kind = "Err", IsThrottled = IsGetBudgetSpent(), Code = Result.Code }
end

local function Update(Target: StoreKey, Transform: Transform): Result
	return ResultOf(function()
		return (DataStoreOf(Target.Store, Target.Scope):UpdateAsync(Target.Key, Transform))
	end)
end

local function Get(Target: StoreKey): Result
	local Result = ResultOf(function()
		return (DataStoreOf(Target.Store, Target.Scope):GetAsync(Target.Key, UncachedGet()))
	end)
	return ReadGetThrottle(Result)
end

local function Remove(Target: StoreKey): Result
	return ResultOf(function()
		return (DataStoreOf(Target.Store, Target.Scope):RemoveAsync(Target.Key))
	end)
end

local function MemoryGet(Map: string, Key: string): Result
	return ResultOf(function()
		return MapOf(Map):GetAsync(Key)
	end)
end

local function MemorySet(Map: string, Key: string, Value: unknown, Expiry: number): Result
	return ResultOf(function()
		return MapOf(Map):SetAsync(Key, Value, Expiry)
	end)
end

local function MemoryUpdate(Map: string, Key: string, Transform: MemoryTransform, Expiry: number): Result
	return ResultOf(function()
		return MapOf(Map):UpdateAsync(Key, Transform, Expiry)
	end)
end

local function MemoryRemove(Map: string, Key: string): Result
	return ResultOf(function()
		MapOf(Map):RemoveAsync(Key)
		return nil
	end)
end

local function KeysPageOf(Pages: DataStoreKeyPages): KeysPage
	local Names: { string } = {}
	for _, Entry in Pages:GetCurrentPage() do
		table.insert(Names, (Entry :: DataStoreKey).KeyName)
	end
	return { Pages = Pages, Names = Names, IsLast = Pages.IsFinished }
end

local function KeysResultOf(Result: Result): KeysResult
	if Result.Kind ~= "Ok" then
		return { Kind = "Err" }
	end
	return { Kind = "Ok", Page = Result.Value :: KeysPage }
end

local function ListKeys(Store: string, Scope: string): KeysResult
	return KeysResultOf(ResultOf(function()
		return KeysPageOf(DataStoreOf(Store, Scope):ListKeysAsync(AnyKeyPrefix, KeysPageSize, nil, ExcludeDeleted))
	end))
end

local function AdvanceKeys(Pages: DataStoreKeyPages): Result
	return ResultOf(function()
		Pages:AdvanceToNextPageAsync()
		return true
	end)
end

local function ReadKeys(Pages: DataStoreKeyPages): KeysResult
	return KeysResultOf(ResultOf(function()
		return KeysPageOf(Pages)
	end))
end

local function JsonDecode(Text: string): Result
	return ResultOf(function()
		return HttpService:JSONDecode(Text)
	end)
end

return {
	Update = Update,
	Get = Get,
	Remove = Remove,
	MemoryGet = MemoryGet,
	MemorySet = MemorySet,
	MemoryUpdate = MemoryUpdate,
	MemoryRemove = MemoryRemove,
	ListKeys = ListKeys,
	AdvanceKeys = AdvanceKeys,
	ReadKeys = ReadKeys,
	JsonDecode = JsonDecode,
}
