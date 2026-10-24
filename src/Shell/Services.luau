--!strict
--!optimize 2

--[=[
	Services: the DataStore, MemoryStore and JSON calls, one request in, one Result out, through ResultOf's one
	pcall; a listing gives one page through PageResultOf's. A failed request's error is not read: a failed Get is
	throttled when this server's GetAsync budget is below 1, every other failure fails plainly. A key listing takes 50
	keys a page, deleted ones left out; a version listing takes the platform's default page (0, which is 1024), oldest
	first, the order named since the Mock defaults to newest first. Server-only services are got at first use. A mock,
	given through a store's Mock option, stands in for both services for the whole server, since Ledger's own stores
	cannot be split from the game's: one mock per server, and only before the first request, so a store opened on the
	real services never continues on it.

	Return type: A plain table with one function per call, and the Result, Page, PageResult, KeyVersion and Transform
	types.
	Example usage:
		local Result = Services.Get({ Store = "Players", Scope = "global", Key = "Alice" })
		if Result.Kind == "Err" and Result.IsThrottled then ... end
--]=]

local GetOrMake = require("../Machine/GetOrMake").GetOrMake
local Names = require("../Record/Encoding/Names")

type StoreKey = Names.StoreKey

export type Result =
	{ read Kind: "Ok", read Value: unknown }
	| { read Kind: "Absent" }
	| { read Kind: "Err", read IsThrottled: boolean }

export type Page<Entry> = {
	read Pages: Pages,
	read Entries: { Entry },
	read IsLast: boolean,
}

export type PageResult<Entry> = { read Kind: "Ok", read Page: Page<Entry> } | { read Kind: "Err" }

export type KeyVersion = {
	read Version: string,
	read CreatedTime: number,
	read IsDeleted: boolean,
}

export type Transform = (Current: unknown) -> (unknown, { number }?)

export type MemoryTransform = (Current: unknown) -> unknown

local HttpService = game:GetService("HttpService")

local KeysPageSize = 50
local AnyKeyPrefix = ""
local ExcludeDeleted = true
local DefaultPageSize = 0
local NoDateBound = 0

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

local function ResultOf(Body: () -> unknown): Result
	local IsReturned, Answer = pcall(Body)
	if not IsReturned then
		return { Kind = "Err", IsThrottled = false }
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
	return { Kind = "Err", IsThrottled = IsGetBudgetSpent() }
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

local function GetVersion(Target: StoreKey, Version: string): Result
	return ResultOf(function()
		return (DataStoreOf(Target.Store, Target.Scope):GetVersionAsync(Target.Key, Version))
	end)
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

local function KeysPageOf(Pages: Pages): Page<string>
	local Names: { string } = {}
	for _, Entry in Pages:GetCurrentPage() do
		table.insert(Names, (Entry :: DataStoreKey).KeyName)
	end
	return { Pages = Pages, Entries = Names, IsLast = Pages.IsFinished }
end

local function VersionsPageOf(Pages: Pages): Page<KeyVersion>
	local Versions: { KeyVersion } = {}
	for _, Entry in Pages:GetCurrentPage() do
		local Info = Entry :: DataStoreObjectVersionInfo
		table.insert(Versions, { Version = Info.Version, CreatedTime = Info.CreatedTime, IsDeleted = Info.IsDeleted })
	end
	return { Pages = Pages, Entries = Versions, IsLast = Pages.IsFinished }
end

local function PageResultOf<Entry>(Body: () -> Page<Entry>): PageResult<Entry>
	local IsReturned, Made = pcall(Body)
	if not IsReturned then
		return { Kind = "Err" }
	end
	return { Kind = "Ok", Page = Made }
end

local function ListKeys(Store: string, Scope: string, Prefix: string?): PageResult<string>
	return PageResultOf(function()
		local Listed =
			DataStoreOf(Store, Scope):ListKeysAsync(Prefix or AnyKeyPrefix, KeysPageSize, nil, ExcludeDeleted)
		return KeysPageOf(Listed)
	end)
end

local function ReadKeys(Pages: Pages): PageResult<string>
	return PageResultOf(function()
		return KeysPageOf(Pages)
	end)
end

local function ListVersions(Target: StoreKey): PageResult<KeyVersion>
	return PageResultOf(function()
		local Listed = DataStoreOf(Target.Store, Target.Scope):ListVersionsAsync(
			Target.Key,
			Enum.SortDirection.Ascending,
			NoDateBound,
			NoDateBound,
			DefaultPageSize
		)
		return VersionsPageOf(Listed)
	end)
end

local function ReadVersions(Pages: Pages): PageResult<KeyVersion>
	return PageResultOf(function()
		return VersionsPageOf(Pages)
	end)
end

local function AdvancePages(Pages: Pages): Result
	return ResultOf(function()
		Pages:AdvanceToNextPageAsync()
		return true
	end)
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
	GetVersion = GetVersion,
	Remove = Remove,
	MemoryGet = MemoryGet,
	MemorySet = MemorySet,
	MemoryUpdate = MemoryUpdate,
	MemoryRemove = MemoryRemove,
	ListKeys = ListKeys,
	ReadKeys = ReadKeys,
	ListVersions = ListVersions,
	ReadVersions = ReadVersions,
	AdvancePages = AdvancePages,
	JsonDecode = JsonDecode,
	UseMock = UseMock,
}
