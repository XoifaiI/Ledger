--!strict
--!optimize 2

--[=[
	Services: the DataStore, MemoryStore and JSON calls, one request in, one Result out, through ResultOf's one
	pcall. A failed request keeps its error's leading code; a failed Get is throttled when this server's GetAsync
	budget is below 1, other throttles failing plainly. A listing takes 50 keys a page, deleted ones left out.
	Server-only services are got at first use. A mock, given through a store's Mock option, stands in for both
	services for the whole server, since Ledger's own stores cannot be split from the game's: one mock per
	server, and only before the first request, so a store opened on the real services never continues on it.

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

local ChosenMock: unknown? = nil
local IsRequested = false

local MockAfterRequest = "Ledger.New: Mock must be given before Ledger's first request on the real services, "
	.. "since a server cannot move its stores from one to the other"
local AnotherMock = "Ledger.New: Mock must be the mock the first store on this server gave, since Ledger's own "
	.. "stores share one set of services with the game's, got another one"

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
	IsRequested = true
	local Mock = ChosenMock
	if Mock ~= nil then
		return Mock :: any
	end
	return game:GetService("DataStoreService")
end

local function GetMemoryStoreService(): MemoryStoreService
	IsRequested = true
	local Mock = ChosenMock
	if Mock ~= nil then
		return Mock :: any
	end
	return game:GetService("MemoryStoreService")
end

local function DataStoreOf(Store: string, Scope: string): DataStore
	local Scopes = GetOrMake(DataStores, Store, NoScopes)
	return GetOrMake(Scopes, Scope, function(): DataStore
		return GetDataStoreService():GetDataStore(Store, Scope)
	end)
end

local function MapOf(Name: string): MemoryStoreHashMap
	return GetOrMake(Maps, Name, function(): MemoryStoreHashMap
		return GetMemoryStoreService():GetHashMap(Name)
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

local function UseMock(Mock: unknown): ()
	local Chosen = ChosenMock
	if Chosen ~= nil then
		if not rawequal(Chosen, Mock) then
			error(AnotherMock, 0)
		end
		return
	end

	if IsRequested then
		error(MockAfterRequest, 0)
	end
	ChosenMock = Mock
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
	UseMock = UseMock,
}
