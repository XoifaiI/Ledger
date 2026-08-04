--!strict
--!optimize 2

--[=[
	Store: One fake datastore.
	
	It holds its keys, and the versions that it keeps of each key.
	A transform can hit a conflict when two writes land on one key. The version mark is read before
	and after the transform, and a change means that another write came in between. The transform
	then runs again against what that write left, which is what a real UpdateAsync does.
	
	Return type: A table with New, MAX_KEY and KEEP_VERSIONS.
	Example usage:
		local Store = require("./Store")
		local Books = Store.New("Players", "global", Service)
--]=]

local NoYield = require("../Util/NoYield")
local Clock = require("../Util/Clock")
local Fault = require("../Contract/Fault")
local Codec = require("./Codec")
local Pages = require("./Pages")
local Types = require("./Types")

type Store = Types.Store
type Slot = Types.Slot
type Entry = Types.Entry
type KeyInfo = Types.KeyInfo
type Transform = Types.Transform

local MAX_KEY = 50
local KEEP_VERSIONS = 30
local CONFLICT_LIMIT = 32

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
		GetMetadata = NoMeta
	})
end

local function CheckKey(Key: string)
	if type(Key) ~= "string" or #Key == 0 then
		error("Ledger mock: key must be a non empty string", 0)
	end
	if #Key > MAX_KEY then
		error(`Ledger mock: key name exceeds the {MAX_KEY} character limit`, 0)
	end
end

local Store = {} :: Types.StoreImpl
Store.__index = Store
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
		Label = `{self.Ticket}`
	}
	Slot.Live = Text
	table.insert(Slot.Entries, Fresh)

	local Spare = #Slot.Entries - KEEP_VERSIONS
	if Spare > 0 then
		Slot.Entries = table.move(Slot.Entries, Spare + 1, #Slot.Entries, 1, {})
	end

	assert(#Slot.Entries <= KEEP_VERSIONS, "the mock is keeping more versions of a key than a real datastore would")
	assert(Newest(Slot) == Fresh, "the mock wrote a version that is not the one a read would hand back")
	return Fresh
end

local function Current(self: Store, Key: string): (any, KeyInfo?)
	local Slot = Held(self, Key)
	local Mark = Newest(Slot)
	local Text = Slot.Live
	if Text == nil or Mark == nil then
		return nil, nil
	end

	self.Service:Carry("r", self.Name, Key, #Text)
	return Codec.Decode(Text), MakeInfo(Mark.Label, Mark.Written)
end

local function Put(self: Store, Key: string, Value: any): Entry
	local Text = Codec.Encode(Value)
	self.Service:Carry("w", self.Name, Key, #Text)
	return Commit(self, Key, Text, false)
end

local function New(Name: string, Scope: string, Service: Types.Service): Store
	return setmetatable({
		Name = Name,
		Scope = Scope,
		Service = Service,
		Slots = {},
		Ticket = 0
	}, Store)
end

function Store.GetAsync(self: Store, Key: string): (any, KeyInfo?)
	CheckKey(Key)
	Reach(self, Enum.DataStoreRequestType.GetAsync)
	return Current(self, Key)
end

function Store.UpdateAsync(self: Store, Key: string, Transform: Transform): (any, KeyInfo?)
	CheckKey(Key)
	Reach(self, Enum.DataStoreRequestType.UpdateAsync)

	for _ = 1, CONFLICT_LIMIT do
		local Latest = Newest(Held(self, Key))
		local Before = if Latest then Latest.Label else nil

		local Was, Info = Current(self, Key)
		local Ran, Next = pcall(NoYield, Transform, Was, Info)
		if not Ran then
			if Fault.Of(Next) ~= nil then
				error(Next, 0)
			end
			error(`Ledger mock: the UpdateAsync transform on '{Key}' yielded, take the wait out of it: {Next}`, 0)
		end
		if Next == nil then
			return nil, nil
		end

		local Moved = Newest(Held(self, Key))
		if (if Moved then Moved.Label else nil) ~= Before then
			continue
		end

		local Fresh = Put(self, Key, Next)
		local Read = Codec.Decode(Fresh.Text)
		assert(Read ~= nil, "the mock stored a transform result it cannot read back, so a round trip loses data")
		return Read, MakeInfo(Fresh.Label, Fresh.Written)
	end

	error(`Ledger mock: UpdateAsync on '{Key}' could not settle, too many conflicting writes`, 0)
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
			return Codec.Decode(Mark.Text), MakeInfo(Mark.Label, Mark.Written)
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
): Types.Pages
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
			IsDeleted = Mark.Deleted
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

function Store.ListKeysAsync(
	self: Store,
	Prefix: string?,
	PageSize: number?,
	Cursor: string?,
	ExcludeDeleted: boolean?
): Types.Pages
	Reach(self, Enum.DataStoreRequestType.ListAsync)

	local Wanted = Prefix or ""
	local Hiding = ExcludeDeleted == true
	local After = if type(Cursor) == "string" then Cursor else ""
	local Names: { string } = {}
	for Key, Slot in self.Slots do
		if Slot.Live == nil and Hiding then
			continue
		end
		if Wanted ~= "" and string.sub(Key, 1, #Wanted) ~= Wanted then
			continue
		end
		if After ~= "" and Key <= After then
			continue
		end
		table.insert(Names, Key)
	end
	table.sort(Names)

	local Rows: { any } = {}
	for _, Key in Names do
		table.insert(Rows, { KeyName = Key })
	end

	return Pages.New(Rows, PageSize, 50, "KeyName")
end

table.freeze(Store)

return table.freeze({
	New = New,
	MAX_KEY = MAX_KEY,
	KEEP_VERSIONS = KEEP_VERSIONS
})
