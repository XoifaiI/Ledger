--!strict
--!optimize 2

-- an in memory datastore that keeps the real one's limits, budgets and queueing, so saves work offline

local HttpService = game:GetService("HttpService")

local Clock = require("./Clock")

local MAX_NAME = 50
local MAX_KEY = 50
local MAX_SCOPE = 50
local MAX_VALUE = 4194304
local KEEP_VERSIONS = 30
local REFILL_WINDOW = 60
local QUEUE_LIMIT = 30
local QUEUE_STEP = 0.05
local PAGE_LIMIT = 100

local READ_BYTES = 25 * 1024 * 1024
local WRITE_BYTES = 4 * 1024 * 1024

local READING = "r"
local WRITING = "w"

local UNSTORABLE = "value cannot be stored, a datastore only holds json"
local THROTTLED = "DataStore request dropped, the queue is full and this server is out of budget"

type Allowance = {
	read Base: number,
	read PerPlayer: number,
}

local STANDARD: Allowance = { Base = 60, PerPlayer = 40 }
local LISTING: Allowance = { Base = 5, PerPlayer = 2 }

local ALLOWANCES: { [string]: Allowance } = {
	GetAsync = STANDARD,
	UpdateAsync = STANDARD,
	SetIncrementAsync = STANDARD,
	GetSortedAsync = STANDARD,
	SetIncrementSortedAsync = STANDARD,
	GetVersionAsync = STANDARD,
	RemoveVersionAsync = STANDARD,
	OnUpdate = STANDARD,
	ListAsync = LISTING,
}

export type Options = {
	Players: number?,
	Throttled: boolean?,
}

export type KeyInfo = {
	read Version: string,
	read CreatedTime: number,
	read UpdatedTime: number,
	read GetUserIds: (self: KeyInfo) -> { number },
	read GetMetadata: (self: KeyInfo) -> { [string]: any },
}

type Entry = {
	Text: string?,
	Written: number,
	Deleted: boolean,
	Label: string,
}

type Slot = {
	Live: string?,
	Entries: { Entry },
}

type Transform = (Current: any, Info: KeyInfo?) -> ...any

type PagesImpl = {
	__index: PagesImpl,
	GetCurrentPage: (self: Pages) -> { any },
	AdvanceToNextPageAsync: (self: Pages) -> (),
}

export type Pages = setmetatable<{
	Rows: { any },
	Cursor: number,
	Size: number,
	IsFinished: boolean,
}, PagesImpl>

type StoreImpl = {
	__index: StoreImpl,
	GetAsync: (self: Store, Key: string) -> (any, KeyInfo?),
	UpdateAsync: (self: Store, Key: string, Transform: Transform) -> (any, KeyInfo?),
	SetAsync: (self: Store, Key: string, Value: any) -> string,
	RemoveAsync: (self: Store, Key: string) -> (any, KeyInfo?),
	GetVersionAsync: (self: Store, Key: string, Version: string) -> (any, KeyInfo?),
	ListVersionsAsync: (
		self: Store,
		Key: string,
		Direction: Enum.SortDirection?,
		MinDate: number?,
		MaxDate: number?,
		PageSize: number?
	) -> Pages,
	ListKeysAsync: (self: Store, Prefix: string?, PageSize: number?, Cursor: string?, ExcludeDeleted: boolean?) -> Pages,
}

export type Store = setmetatable<{
	Name: string,
	Scope: string,
	Service: Service,
	Slots: { [string]: Slot },
	Ticket: number,
}, StoreImpl>

type ServiceImpl = {
	__index: ServiceImpl,
	GetDataStore: (self: Service, Name: string, Scope: string?) -> Store,
	GetRequestBudgetForRequestType: (self: Service, Kind: Enum.DataStoreRequestType) -> number,
	Spend: (self: Service, Kind: Enum.DataStoreRequestType) -> (),
	Carry: (self: Service, Way: string, Store: string, Key: string, Bytes: number) -> (),
	Clear: (self: Service) -> (),
}

export type Service = setmetatable<{
	Stores: { [string]: Store },
	Tokens: { [string]: number },
	Filled: { [string]: number },
	Queued: number,
	Players: number,
	Throttled: boolean,
}, ServiceImpl>

local Pages = {} :: PagesImpl
Pages.__index = Pages

local Store = {} :: StoreImpl
Store.__index = Store

local Service = {} :: ServiceImpl
Service.__index = Service

local function NoIds(_self: KeyInfo): { number }
	return {}
end

local function NoMeta(_self: KeyInfo): { [string]: any }
	return {}
end

local function MakeInfo(Label: string, Written: number): KeyInfo
	return table.freeze({
		Version = Label,
		CreatedTime = Written * 1000,
		UpdatedTime = Written * 1000,
		GetUserIds = NoIds,
		GetMetadata = NoMeta,
	})
end

local function CheckName(Name: string)
	if type(Name) ~= "string" or #Name == 0 then
		error("Ledger mock: a datastore name must be a non empty string", 0)
	end
	if #Name > MAX_NAME then
		error(`Ledger mock: datastore name exceeds the {MAX_NAME} character limit`, 0)
	end
end

local function CheckKey(Key: string)
	if type(Key) ~= "string" or #Key == 0 then
		error("Ledger mock: key must be a non empty string", 0)
	end
	if #Key > MAX_KEY then
		error(`Ledger mock: key name exceeds the {MAX_KEY} character limit`, 0)
	end
end

local function Encode(Value: any): string
	local Fine, Text = pcall(function(): string
		return HttpService:JSONEncode(Value)
	end)
	if not Fine or type(Text) ~= "string" then
		error(`Ledger mock: {UNSTORABLE}`, 0)
	end
	if #Text > MAX_VALUE then
		error(`Ledger mock: value is larger than the {MAX_VALUE} byte limit`, 0)
	end
	return Text
end

local function Decode(Text: string?): any
	if Text == nil then
		return nil
	end

	local Fine, Value = pcall(function(): any
		return HttpService:JSONDecode(Text :: string)
	end)
	return if Fine then Value else nil
end

function Pages.GetCurrentPage(self: Pages): { any }
	local Last = math.min(self.Cursor + self.Size - 1, #self.Rows)
	return table.move(self.Rows, self.Cursor, Last, 1, {})
end

function Pages.AdvanceToNextPageAsync(self: Pages)
	if self.IsFinished then
		error("Ledger mock: there are no pages left to advance to", 0)
	end

	self.Cursor += self.Size
	self.IsFinished = self.Cursor + self.Size > #self.Rows
end

local function MakePages(Rows: { any }, PageSize: number?, Fallback: number): Pages
	local Size = math.clamp(PageSize or Fallback, 1, PAGE_LIMIT)
	return setmetatable({
		Rows = Rows,
		Cursor = 1,
		Size = Size,
		IsFinished = Size >= #Rows,
	}, Pages)
end

local function Ceiling(self: Service, Kind: Enum.DataStoreRequestType): number
	local Allowance = ALLOWANCES[Kind.Name] or STANDARD
	return Allowance.Base + Allowance.PerPlayer * self.Players
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

local function Await(self: Service, Id: string, Cap: number, Cost: number)
	if Refill(self, Id, Cap) >= Cost then
		self.Tokens[Id] -= Cost
		return
	end

	if self.Queued >= QUEUE_LIMIT then
		error(`Ledger mock: {THROTTLED}`, 0)
	end

	self.Queued += 1
	while Refill(self, Id, Cap) < Cost do
		task.wait(QUEUE_STEP)
	end
	self.Queued -= 1
	self.Tokens[Id] -= Cost
end

function Service.GetRequestBudgetForRequestType(self: Service, Kind: Enum.DataStoreRequestType): number
	return math.floor(Refill(self, `q\0{Kind.Name}`, Ceiling(self, Kind)))
end

function Service.Spend(self: Service, Kind: Enum.DataStoreRequestType)
	if not self.Throttled then
		return
	end
	Await(self, `q\0{Kind.Name}`, Ceiling(self, Kind), 1)
end

function Service.Carry(self: Service, Way: string, Store: string, Key: string, Bytes: number)
	if not self.Throttled or Bytes <= 0 then
		return
	end

	local Cap = if Way == WRITING then WRITE_BYTES else READ_BYTES
	Await(self, `{Way}\0{Store}\0{Key}`, Cap, math.min(Bytes, Cap))
end

function Service.Clear(self: Service)
	table.clear(self.Stores)
	table.clear(self.Tokens)
	table.clear(self.Filled)
	self.Queued = 0
end

function Service.GetDataStore(self: Service, Name: string, Scope: string?): Store
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

	local Fresh: Store = setmetatable({
		Name = Name,
		Scope = Where,
		Service = self,
		Slots = {},
		Ticket = 0,
	}, Store)
	self.Stores[Id] = Fresh
	return Fresh
end

local function Reach(self: Store, Kind: Enum.DataStoreRequestType)
	self.Service:Spend(Kind)
	task.wait()
end

local function Held(self: Store, Key: string): Slot
	local Found = self.Slots[Key]
	if Found ~= nil then
		return Found
	end

	local Fresh: Slot = { Live = nil, Entries = {} }
	self.Slots[Key] = Fresh
	return Fresh
end

local function Newest(Slot: Slot): Entry?
	return Slot.Entries[#Slot.Entries]
end

local function Commit(self: Store, Key: string, Text: string?, Deleted: boolean): Entry
	local Slot = Held(self, Key)
	self.Ticket += 1

	local Fresh: Entry = {
		Text = Text,
		Written = Clock.Now(),
		Deleted = Deleted,
		Label = `{self.Ticket}`,
	}
	Slot.Live = Text
	table.insert(Slot.Entries, Fresh)

	local Spare = #Slot.Entries - KEEP_VERSIONS
	if Spare > 0 then
		Slot.Entries = table.move(Slot.Entries, Spare + 1, #Slot.Entries, 1, {})
	end

	return Fresh
end

local function Current(self: Store, Key: string): (any, KeyInfo?)
	local Slot = Held(self, Key)
	local Mark = Newest(Slot)
	local Text = Slot.Live
	if Text == nil or Mark == nil then
		return nil, nil
	end

	self.Service:Carry(READING, self.Name, Key, #Text)
	return Decode(Text), MakeInfo(Mark.Label, Mark.Written)
end

local function Put(self: Store, Key: string, Value: any): Entry
	local Text = Encode(Value)
	self.Service:Carry(WRITING, self.Name, Key, #Text)
	return Commit(self, Key, Text, false)
end

function Store.GetAsync(self: Store, Key: string): (any, KeyInfo?)
	CheckKey(Key)
	Reach(self, Enum.DataStoreRequestType.GetAsync)
	return Current(self, Key)
end

function Store.UpdateAsync(self: Store, Key: string, Transform: Transform): (any, KeyInfo?)
	CheckKey(Key)
	Reach(self, Enum.DataStoreRequestType.UpdateAsync)

	local Was, Info = Current(self, Key)
	local Next = Transform(Was, Info)
	if Next == nil then
		return nil, nil
	end

	local Fresh = Put(self, Key, Next)
	return Decode(Fresh.Text), MakeInfo(Fresh.Label, Fresh.Written)
end

function Store.SetAsync(self: Store, Key: string, Value: any): string
	CheckKey(Key)
	Reach(self, Enum.DataStoreRequestType.SetIncrementAsync)
	return Put(self, Key, Value).Label
end

function Store.RemoveAsync(self: Store, Key: string): (any, KeyInfo?)
	CheckKey(Key)
	Reach(self, Enum.DataStoreRequestType.SetIncrementAsync)

	local Was, Info = Current(self, Key)
	if Info == nil then
		return nil, nil
	end

	Commit(self, Key, nil, true)
	return Was, Info
end

function Store.GetVersionAsync(self: Store, Key: string, Version: string): (any, KeyInfo?)
	CheckKey(Key)
	Reach(self, Enum.DataStoreRequestType.GetVersionAsync)

	for _, Mark in Held(self, Key).Entries do
		if Mark.Label == Version then
			return Decode(Mark.Text), MakeInfo(Mark.Label, Mark.Written)
		end
	end

	error(`Ledger mock: no version '{Version}' for key '{Key}'`, 0)
end

function Store.ListVersionsAsync(
	self: Store,
	Key: string,
	Direction: Enum.SortDirection?,
	MinDate: number?,
	MaxDate: number?,
	PageSize: number?
): Pages
	CheckKey(Key)
	Reach(self, Enum.DataStoreRequestType.ListAsync)

	local Rows: { any } = {}
	for _, Mark in Held(self, Key).Entries do
		local Stamp = Mark.Written * 1000
		if MinDate ~= nil and Stamp < MinDate then
			continue
		end
		if MaxDate ~= nil and Stamp > MaxDate then
			continue
		end
		table.insert(Rows, {
			Version = Mark.Label,
			CreatedTime = Stamp,
			IsDeleted = Mark.Deleted,
		})
	end

	if Direction ~= Enum.SortDirection.Ascending then
		local Flipped: { any } = {}
		for Index = #Rows, 1, -1 do
			table.insert(Flipped, Rows[Index])
		end
		Rows = Flipped
	end

	return MakePages(Rows, PageSize, 25)
end

function Store.ListKeysAsync(
	self: Store,
	Prefix: string?,
	PageSize: number?,
	_Cursor: string?,
	ExcludeDeleted: boolean?
): Pages
	Reach(self, Enum.DataStoreRequestType.ListAsync)

	local Wanted = Prefix or ""
	local Hiding = ExcludeDeleted == true
	local Names: { string } = {}
	for Key, Slot in self.Slots do
		if Slot.Live == nil and Hiding then
			continue
		end
		if Wanted ~= "" and string.sub(Key, 1, #Wanted) ~= Wanted then
			continue
		end
		table.insert(Names, Key)
	end
	table.sort(Names)

	local Rows: { any } = {}
	for _, Key in Names do
		table.insert(Rows, { KeyName = Key })
	end

	return MakePages(Rows, PageSize, 50)
end

local function New(Options: Options?): Service
	local Config: Options = Options or {}
	return setmetatable({
		Stores = {},
		Tokens = {},
		Filled = {},
		Queued = 0,
		Players = Config.Players or 0,
		Throttled = Config.Throttled ~= false,
	}, Service)
end

table.freeze(Pages)
table.freeze(Store)
table.freeze(Service)

return table.freeze({
	New = New,
	MAX_NAME = MAX_NAME,
	MAX_KEY = MAX_KEY,
	MAX_VALUE = MAX_VALUE,
	KEEP_VERSIONS = KEEP_VERSIONS,
})
