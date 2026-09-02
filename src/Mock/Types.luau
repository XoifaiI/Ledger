--!strict
--!optimize 2

--[=[

	Types: The declarations of the fake datastore.

	These are private to this folder. This file holds declarations, and never logic. A service hands
	out stores and hash maps and each spends from its service, so every shape is named here rather
	than in any of those files.

	Return type: An empty table. The types are Options, KeyInfo, Entry, Slot, Transform, Allowance, Budget, Lane, Pages, Store, Item, MapTransform, HashMap and Service.
	Example usage:
		local Types = require("./Types")
		type Service = Types.Service
--]=]

local Engine = require("../Util/Engine")
local Shapes = require("../Core/Shapes")

export type Options = Shapes.Mocked

export type KeyInfo = {
	read Version: string,
	read CreatedTime: number,
	read UpdatedTime: number,
	read GetUserIds: (self: KeyInfo) -> { number },
	read GetMetadata: (self: KeyInfo) -> { [string]: any },
}

export type Entry = {
	Text: string?,
	Written: number,
	Deleted: boolean,
	Label: string,
}

export type Slot = {
	Live: string?,
	Entries: { Entry },
}

export type Transform = (Current: any, Info: KeyInfo?) -> ...any

export type Allowance = {
	read Base: number,
	read PerPlayer: number,
}

export type Budget = {
	read Server: Allowance,
	read Experience: Allowance,
}

export type Lane = {
	read Id: string,
	read Cap: number,
}

export type PagesImpl = {
	__index: PagesImpl,
	New: (Rows: { any }, PageSize: number?, Fallback: number, Mark: ((At: number) -> string)?, Spend: (() -> ())?) -> Pages,
	Edge: (self: Pages) -> (),
	GetCurrentPage: (self: Pages) -> { any },
	AdvanceToNextPageAsync: (self: Pages) -> (),
}

export type Pages = setmetatable<{
	Rows: { any },
	At: number,
	Size: number,
	Mark: ((At: number) -> string)?,
	Spend: (() -> ())?,
	Cursor: string,
	IsFinished: boolean,
}, PagesImpl>

export type StoreImpl = {
	__index: StoreImpl,
	New: (Name: string, Scope: string, Service: Service) -> Store,
	Reach: (self: Store, Kind: Enum.DataStoreRequestType) -> (),
	Held: (self: Store, Key: string) -> Slot,
	Look: (self: Store, Key: string) -> Slot?,
	Commit: (self: Store, Key: string, Text: string?, Deleted: boolean) -> Entry,
	Current: (self: Store, Key: string) -> (any, KeyInfo?),
	Put: (self: Store, Key: string, Value: any) -> Entry,
	GetAsync: (self: Store, Key: string) -> (any, KeyInfo?),
	UpdateAsync: (self: Store, Key: string, Transform: Transform) -> (any, KeyInfo?),
	SetAsync: (self: Store, Key: string, Value: any) -> string,
	RemoveAsync: (self: Store, Key: string) -> (any, KeyInfo?),
	GetVersionAsync: (self: Store, Key: string, Version: string) -> (any, KeyInfo?),
	ListVersionsAsync: (self: Store, Key: string, Direction: Enum.SortDirection?, MinDate: number?, MaxDate: number?, PageSize: number?) -> Pages,
	ListKeysAsync: (self: Store, Prefix: string?, PageSize: number?, Cursor: string?, ExcludeDeleted: boolean?) -> Pages,
}

export type Store = setmetatable<{
	Name: string,
	Scope: string,
	Service: Service,
	Slots: { [string]: Slot },
	Names: { string },
	Ticket: number,
}, StoreImpl>

export type Item = {
	Text: string,
	Ends: number,
	Ticket: number,
}

export type MapTransform = (Current: any) -> any

export type HashMapImpl = {
	__index: HashMapImpl,
	New: (Name: string, Service: Service) -> HashMap,
	Reach: (self: HashMap, Cost: number) -> (),
	Held: (self: HashMap, Key: string) -> Item?,
	Put: (self: HashMap, Key: string, Value: any, Expiry: number) -> any,
	GetAsync: (self: HashMap, Key: string) -> any,
	SetAsync: (self: HashMap, Key: string, Value: any, Expiry: number) -> boolean,
	UpdateAsync: (self: HashMap, Key: string, Transform: MapTransform, Expiry: number) -> any,
	RemoveAsync: (self: HashMap, Key: string) -> (),
}

export type HashMap = setmetatable<{
	Name: string,
	Service: Service,
	Items: { [string]: Item },
	Ticket: number,
}, HashMapImpl>

export type ServiceImpl = {
	__index: ServiceImpl,
	New: (Options: Options?, Scheduler: Engine.Scheduler?) -> Service,
	ServerCap: (self: Service, Kind: Enum.DataStoreRequestType) -> number,
	LanesFor: (self: Service, Kind: Enum.DataStoreRequestType) -> { Lane },
	Refill: (self: Service, Id: string, Cap: number) -> number,
	Ready: (self: Service, Lanes: { Lane }, Cost: number) -> boolean,
	Take: (self: Service, Lanes: { Lane }, Cost: number) -> (),
	Await: (self: Service, Lanes: { Lane }, Cost: number) -> (),
	GetDataStore: (self: Service, Name: string, Scope: string?) -> Store,
	GetHashMap: (self: Service, Name: string) -> HashMap,
	GetRequestBudgetForRequestType: (self: Service, Kind: Enum.DataStoreRequestType) -> number,
	Spend: (self: Service, Kind: Enum.DataStoreRequestType) -> (),
	Charge: (self: Service, Cost: number) -> (),
	Carry: (self: Service, Way: string, Store: string, Key: string, Bytes: number) -> (),
	Clear: (self: Service) -> (),
}

export type Service = setmetatable<{
	Scheduler: Engine.Scheduler,
	Stores: { [string]: Store },
	Maps: { [string]: HashMap },
	Tokens: { [string]: number },
	Filled: { [string]: number },
	Queued: number,
	Conflicts: number,
	Units: number,
	Players: number,
	CCU: number,
	Throttled: boolean,
}, ServiceImpl>

return table.freeze({})
