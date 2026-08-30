--!strict
--!optimize 2

--[=[

	Store: One fake datastore.

	It holds its keys and the versions it keeps of each. Two writes on one key can meet, so a
	transform runs again when another write landed between its read and its write. A transform that
	yields raises, and one that throws cancels the write silently. A listing comes back in a stable
	order that is not the key order, since a real one gives no order to lean on.

	Return type: A table with New.
	Example usage:
		local Store = require("./Store")
		local Books = Store.New("Players", "global", Service)
--]=]

local Messages = require("../Core/Constants/Messages")
local NoYield = require("../Util/NoYield")
local Clock = require("../Util/Clock")
local Datastore = require("../Core/Constants/Datastore")
local Codec = require("./Codec")
local Pages = require("./Pages")
local Types = require("./Types")

type Store = Types.Store
type Slot = Types.Slot
type Entry = Types.Entry
type KeyInfo = Types.KeyInfo
type Transform = Types.Transform


local HASH_SEED = 5381
local HASH_STEP = 33
local HASH_WRAP = 2 ^ 32

local CURSOR = "c%08x"
local CURSOR_PATTERN = "^c(%x+)$"

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

local function CheckKey(Key: string)
	if type(Key) ~= "string" or #Key == 0 then
		error("Ledger mock: key must be a non empty string", 0)
	end
	if #Key > Datastore.MAX_KEY then
		error(`Ledger mock: key name exceeds the {Datastore.MAX_KEY} character limit`, 0)
	end
end

local function Newest(Slot: Slot?): Entry?
	if Slot == nil then
		return nil
	end
	return Slot.Entries[#Slot.Entries]
end

local function Hashed(Key: string): number
	local Held = HASH_SEED
	for Index = 1, #Key do
		Held = (Held * HASH_STEP + string.byte(Key, Index)) % HASH_WRAP
	end
	return Held
end

local function Ordered(Left: string, Right: string): boolean
	local Mine, Theirs = Hashed(Left), Hashed(Right)
	if Mine ~= Theirs then
		return Mine < Theirs
	end
	return Left < Right
end

local function Spot(Names: { string }, Key: string): number
	local Low, High = 1, #Names + 1
	while Low < High do
		local Mid = (Low + High) // 2
		if Names[Mid] < Key then
			Low = Mid + 1
		else
			High = Mid
		end
	end
	return Low
end

local function Resume(Cursor: string?): number
	if type(Cursor) ~= "string" then
		return 1
	end

	local Digits = string.match(Cursor, CURSOR_PATTERN)
	local Held = if Digits == nil then nil else tonumber(Digits, 16)
	return if Held == nil or Held < 1 then 1 else Held
end

local Store = {} :: Types.StoreImpl
Store.__index = Store

function Store.New(Name: string, Scope: string, Service: Types.Service): Store
	return setmetatable({
		Name = Name,
		Scope = Scope,
		Service = Service,
		Slots = {},
		Names = {},
		Ticket = 0,
	}, Store)
end

function Store.Reach(self: Store, Kind: Enum.DataStoreRequestType)
	self.Service:Spend(Kind)
	self.Service.Scheduler.Wait(0)
end

function Store.Held(self: Store, Key: string): Slot
	local Found = self.Slots[Key]
	if Found ~= nil then
		return Found
	end

	local Fresh: Slot = { Live = nil, Entries = {} }
	self.Slots[Key] = Fresh
	table.insert(self.Names, Spot(self.Names, Key), Key)
	return Fresh
end

function Store.Look(self: Store, Key: string): Slot?
	return self.Slots[Key]
end

function Store.Commit(self: Store, Key: string, Text: string?, Deleted: boolean): Entry
	local Slot = self:Held(Key)
	self.Ticket += 1

	local Fresh: Entry = {
		Text = Text,
		Written = Clock.Now(),
		Deleted = Deleted,
		Label = `{self.Ticket}`,
	}
	Slot.Live = Text
	table.insert(Slot.Entries, Fresh)

	local Spare = #Slot.Entries - Datastore.KEEP_VERSIONS
	if Spare > 0 then
		Slot.Entries = table.move(Slot.Entries, Spare + 1, #Slot.Entries, 1, {})
	end

	assert(#Slot.Entries <= Datastore.KEEP_VERSIONS, "the mock is keeping more versions of a key than a real datastore would")
	assert(Newest(Slot) == Fresh, "the mock wrote a version that is not the one a read would hand back")
	return Fresh
end

function Store.Current(self: Store, Key: string): (any, KeyInfo?)
	local Slot = self:Look(Key)
	local Mark = Newest(Slot)
	local Text = if Slot == nil then nil else Slot.Live
	if Text == nil or Mark == nil then
		return nil, nil
	end

	self.Service:Carry("r", self.Name, Key, #Text)
	return Codec.Decode(Text), MakeInfo(Mark.Label, Mark.Written)
end

function Store.Put(self: Store, Key: string, Value: any): Entry
	local Text = Codec.Encode(Value)
	self.Service:Carry("w", self.Name, Key, #Text)
	return self:Commit(Key, Text, false)
end

function Store.GetAsync(self: Store, Key: string): (any, KeyInfo?)
	CheckKey(Key)
	self:Reach(Enum.DataStoreRequestType.GetAsync)
	return self:Current(Key)
end

function Store.UpdateAsync(self: Store, Key: string, Transform: Transform): (any, KeyInfo?)
	CheckKey(Key)
	self:Reach(Enum.DataStoreRequestType.UpdateAsync)

	for _ = 1, Datastore.CONFLICT_LIMIT do
		local Latest = Newest(self:Look(Key))
		local Before = if Latest then Latest.Label else nil

		local Was, Info = self:Current(Key)
		local Ran, Next = NoYield.Try(Transform, Was, Info)
		if not Ran then
			if type(Next) == "string" and string.find(Next, Messages.YIELDED, 1, true) ~= nil then
				error(`Ledger mock: the UpdateAsync transform on '{Key}' yielded, take the wait out of it: {Next}`, 0)
			end
			return nil, nil
		end
		if Next == nil then
			return nil, nil
		end

		local Moved = Newest(self:Look(Key))
		if (if Moved then Moved.Label else nil) ~= Before then
			continue
		end

		local Fresh = self:Put(Key, Next)
		local Read = Codec.Decode(Fresh.Text)
		assert(Read ~= nil, "the mock stored a transform result it cannot read back, so a round trip loses data")
		return Read, MakeInfo(Fresh.Label, Fresh.Written)
	end

	error(`Ledger mock: UpdateAsync on '{Key}' could not settle, too many conflicting writes`, 0)
end

function Store.SetAsync(self: Store, Key: string, Value: any): string
	CheckKey(Key)
	self:Reach(Enum.DataStoreRequestType.SetIncrementAsync)
	return self:Put(Key, Value).Label
end

function Store.RemoveAsync(self: Store, Key: string): (any, KeyInfo?)
	CheckKey(Key)
	self:Reach(Enum.DataStoreRequestType.SetIncrementAsync)

	local Was, Info = self:Current(Key)
	if Info == nil then
		return nil, nil
	end

	self:Commit(Key, nil, true)
	return Was, Info
end

function Store.GetVersionAsync(self: Store, Key: string, Version: string): (any, KeyInfo?)
	CheckKey(Key)
	self:Reach(Enum.DataStoreRequestType.GetVersionAsync)

	local Slot = self:Look(Key)
	for _, Mark in if Slot == nil then {} else Slot.Entries do
		if Mark.Label == Version then
			return Codec.Decode(Mark.Text), MakeInfo(Mark.Label, Mark.Written)
		end
	end

	error(`Ledger mock: no version '{Version}' for key '{Key}'`, 0)
end

function Store.ListVersionsAsync(self: Store, Key: string, Direction: Enum.SortDirection?, MinDate: number?, MaxDate: number?, PageSize: number?): Types.Pages
	CheckKey(Key)
	self:Reach(Enum.DataStoreRequestType.ListAsync)

	local Slot = self:Look(Key)
	local Rows: { any } = {}
	for _, Mark in if Slot == nil then {} else Slot.Entries do
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

	return Pages.New(Rows, PageSize, 25)
end

function Store.ListKeysAsync(self: Store, Prefix: string?, PageSize: number?, Cursor: string?, ExcludeDeleted: boolean?): Types.Pages
	self:Reach(Enum.DataStoreRequestType.ListAsync)

	local Wanted = Prefix or ""
	local Hiding = ExcludeDeleted == true
	local Names = self.Names

	local Found: { string } = {}
	for Index = Spot(Names, Wanted), #Names do
		local Key = Names[Index]
		if Wanted ~= "" and string.sub(Key, 1, #Wanted) ~= Wanted then
			break
		end

		local Slot = self.Slots[Key]
		if Slot ~= nil and (Slot.Live ~= nil or not Hiding) then
			table.insert(Found, Key)
		end
	end
	table.sort(Found, Ordered)

	local From = Resume(Cursor)
	local Rows: { any } = {}
	for Index = From, #Found do
		table.insert(Rows, { KeyName = Found[Index] })
	end

	return Pages.New(Rows, PageSize, 50, function(At: number): string
		return string.format(CURSOR, From + At - 1)
	end, function()
		self:Reach(Enum.DataStoreRequestType.ListAsync)
	end)
end

table.freeze(Store)

return table.freeze({
	New = Store.New,
})
