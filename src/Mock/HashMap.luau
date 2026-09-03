--!strict
--!optimize 2

--[=[

	HashMap: One fake MemoryStore hash map.

	It keeps the limits the real one keeps and refuses more. A key holds no byte below a space. An
	item has to read back as it went in. So it turns away a buffer, a mixed table, a sparse array and
	nan, all of which the real service mangles quietly. A transform may not yield, where the real one
	lets it.

	An item lives on the scheduler's clock. Two writes on one key can meet, so a transform runs again
	when another write landed between its read and its write.

	Return type: A table with New.
	Example usage:
		local HashMap = require("./HashMap")
		local Leases = HashMap.New("Ledger_Lease", Service)
--]=]

local Messages = require("../Core/Constants/Messages")
local NoYield = require("../Util/NoYield")
local TableUtil = require("../Util/TableUtil")
local Datastore = require("../Core/Constants/Datastore")
local MemoryStore = require("../Core/Constants/MemoryStore")
local Storable = require("../Encode/Storable")
local Types = require("./Types")

type HashMap = Types.HashMap
type Item = Types.Item
type MapTransform = Types.MapTransform

local HttpService = game:GetService("HttpService")

local function CheckKey(Key: any)
	if type(Key) ~= "string" or #Key == 0 then
		error("Ledger mock: a MemoryStore key must be a non empty string", 0)
	end
	if #Key > MemoryStore.MAX_KEY then
		error(`Ledger mock: MemoryStore key exceeds the {MemoryStore.MAX_KEY} character limit`, 0)
	end

	for Index = 1, #Key do
		if (string.byte(Key, Index) :: number) < MemoryStore.KEY_FLOOR then
			error("Ledger mock: a MemoryStore key cannot hold a byte below a space", 0)
		end
	end
end

local function CheckExpiry(Expiry: any)
	if type(Expiry) ~= "number" then
		error("Ledger mock: a MemoryStore write needs an expiry in seconds", 0)
	end
	if Expiry ~= Expiry or Expiry < 0 or Expiry > MemoryStore.MAX_EXPIRY then
		error(`Ledger mock: a MemoryStore expiry must be between 0 and {MemoryStore.MAX_EXPIRY} seconds`, 0)
	end
end

local function Decode(Text: string): any
	return HttpService:JSONDecode(Text)
end

local function Encode(Value: any): string
	if Value == nil then
		error("Ledger mock: a MemoryStore item cannot be nil", 0)
	end

	local Fits, Where = Storable.Structure(Value)
	if not Fits then
		error(`Ledger mock: a MemoryStore item has to read back as it went in, {Where}`, 0)
	end

	local Fine, Text = pcall(function(): string
		return HttpService:JSONEncode(Value)
	end)
	if not Fine or type(Text) ~= "string" then
		error("Ledger mock: a MemoryStore item has to be json", 0)
	end
	if #Text > MemoryStore.MAX_ITEM then
		error(`Ledger mock: a MemoryStore item is larger than the {MemoryStore.MAX_ITEM} byte limit`, 0)
	end

	local Again, Back = pcall(Decode, Text)
	if not Again or not TableUtil.DeepEqual(Back, Value) then
		error("Ledger mock: a MemoryStore item has to read back as it went in", 0)
	end
	return Text
end

local HashMap = {} :: Types.HashMapImpl
HashMap.__index = HashMap

function HashMap.New(Name: string, Service: Types.Service): HashMap
	return setmetatable({
		Name = Name,
		Service = Service,
		Items = {},
		Ticket = 0,
	}, HashMap)
end

function HashMap.Reach(self: HashMap, Cost: number)
	self.Service:Charge(self.Name, Cost)
	self.Service.Scheduler.Wait(0)
end

local function Weight(Key: string, Text: string): number
	return (#Key + #Text) * MemoryStore.MEMORY_OVERHEAD
end

function HashMap.Drop(self: HashMap, Key: string, Item: Item)
	self.Items[Key] = nil
	self.Service:Hold(-Weight(Key, Item.Text))
end

function HashMap.Held(self: HashMap, Key: string): Item?
	local Item = self.Items[Key]
	if Item == nil then
		return nil
	end
	if self.Service.Scheduler.Now() >= Item.Ends then
		self:Drop(Key, Item)
		return nil
	end
	return Item
end

function HashMap.Sweep(self: HashMap)
	local Now = self.Service.Scheduler.Now()
	for Key, Item in self.Items do
		if Now >= Item.Ends then
			self:Drop(Key, Item)
		end
	end
end

function HashMap.Put(self: HashMap, Key: string, Value: any, Expiry: number): any
	local Text = Encode(Value)
	local Held = self:Held(Key)
	local Was = if Held ~= nil then Weight(Key, Held.Text) else 0
	self.Service:Room(Weight(Key, Text) - Was)

	if Held ~= nil then
		self:Drop(Key, Held)
	end
	self.Ticket += 1
	self.Items[Key] = { Text = Text, Ends = self.Service.Scheduler.Now() + Expiry, Ticket = self.Ticket }
	self.Service:Hold(Weight(Key, Text))
	return Decode(Text)
end

function HashMap.GetAsync(self: HashMap, Key: string): any
	CheckKey(Key)
	self:Reach(MemoryStore.UNIT)

	local Item = self:Held(Key)
	return if Item == nil then nil else Decode(Item.Text)
end

function HashMap.SetAsync(self: HashMap, Key: string, Value: any, Expiry: number): boolean
	CheckKey(Key)
	CheckExpiry(Expiry)
	self:Reach(MemoryStore.UNIT)

	self:Put(Key, Value, Expiry)
	return true
end

function HashMap.UpdateAsync(self: HashMap, Key: string, Transform: MapTransform, Expiry: number): any
	CheckKey(Key)
	CheckExpiry(Expiry)
	self:Reach(MemoryStore.UPDATE_UNITS)

	for _ = 1, Datastore.CONFLICT_LIMIT do
		local Latest = self:Held(Key)
		local Before = if Latest then Latest.Ticket else nil
		local Was = if Latest then Decode(Latest.Text) else nil
		self.Service.Scheduler.Wait(0)

		local Ran, Next = NoYield.Try(Transform, Was)
		if not Ran then
			if type(Next) == "string" and string.find(Next, Messages.YIELDED, 1, true) ~= nil then
				error(`Ledger mock: the UpdateAsync transform on '{Key}' yielded, take the wait out of it: {Next}`, 0)
			end
			error(`Ledger mock: the UpdateAsync transform on '{Key}' threw, so nothing was written: {Next}`, 0)
		end
		if Next == nil then
			return nil
		end

		local Moved = self:Held(Key)
		if (if Moved then Moved.Ticket else nil) ~= Before then
			self.Service.Conflicts += 1
			continue
		end

		return self:Put(Key, Next, Expiry)
	end

	error(`Ledger mock: UpdateAsync on '{Key}' could not settle, too many conflicting writes`, 0)
end

function HashMap.RemoveAsync(self: HashMap, Key: string)
	CheckKey(Key)
	self:Reach(MemoryStore.UNIT)

	local Item = self.Items[Key]
	if Item ~= nil then
		self:Drop(Key, Item)
	end
end

table.freeze(HashMap)

return table.freeze({
	New = HashMap.New,
})
