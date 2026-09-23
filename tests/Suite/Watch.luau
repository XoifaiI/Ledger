--!strict
--!optimize 2

--[=[

	Watch: What must hold after every write Ledger makes, checked as it lands.

	Every datastore write a store makes passes through the fault proxy, and the proxy hands the
	version before and the version after to Around. A fixture writing the mock itself is never
	judged, so a case can still plant a broken record. The proxy sees each write as it lands, so a
	state that goes wrong and then heals is still caught.

	Two rules hold. A transaction never commits a leg on one key and rolls back a leg of the same
	generation on another. The marker of a committed transaction never goes, or reads as aborted,
	while a leg of that generation is still parked on a key.

	Return type: A table with New. The type is Watch.
	Example usage:
		local Watching = Watch.New(Service)
		local Hook = Fault.Wrap(Memory.New(Turn, nil, Service), Turn, Watching)
--]=]

local Json = require("../../src/Mock/Json")
local Mock = require("../../src/Mock")
local Transactions = require("../../src/Core/Constants/Transactions")

local SUFFIX = Transactions.SUFFIX
local RESERVED = Transactions.RESERVED
local PARKED = '"Tx":"'

type Outcome = {
	Committed: { [string]: boolean },
	Dropped: { [string]: boolean },
}

type WatchImpl = {
	__index: WatchImpl,
	New: (Service: Mock.Service) -> Watch,
	Around: (self: Watch, Name: string, Inner: any, Key: string, Call: () -> ...any) -> ...any,
	Judge: (self: Watch, Name: string, Key: string, Prior: string?, After: string?) -> (),
	Legs: (self: Watch, Name: string, Key: string, Prior: string, After: string?) -> (),
	Marker: (self: Watch, Name: string, Key: string, Prior: string, After: string?) -> (),
	Say: (self: Watch, Line: string) -> (),
}

export type Watch = setmetatable<{
	Service: Mock.Service,
	Outcomes: { [string]: Outcome },
	Broke: { string },
	Said: { [string]: boolean },
}, WatchImpl>

local function Latest(Slot: any): any
	if Slot == nil then
		return nil
	end
	return Slot.Entries[#Slot.Entries]
end

local function Before(Slot: any, After: any): any
	local Entries = Slot.Entries
	for Index = #Entries, 2, -1 do
		if Entries[Index] == After then
			return Entries[Index - 1]
		end
	end
	return nil
end

local function Ops(Text: string?): { [string]: any }
	local Record = Json.Decode(Text)
	local Found: { [string]: any } = {}
	if type(Record) ~= "table" or type(Record.Ops) ~= "table" then
		return Found
	end
	for _, Op in Record.Ops do
		if type(Op) == "table" and type(Op.Id) == "string" then
			Found[Op.Id] = Op
		end
	end
	return Found
end

local function Aborted(Value: any, Gen: string): boolean
	return type(Value) ~= "table" or Value.Dead == true or Value.Gen ~= Gen
end

local Watch = {} :: WatchImpl
Watch.__index = Watch

function Watch.New(Service: Mock.Service): Watch
	return setmetatable({
		Service = Service,
		Outcomes = {},
		Broke = {},
		Said = {},
	}, Watch)
end

function Watch.Say(self: Watch, Line: string)
	if self.Said[Line] then
		return
	end
	self.Said[Line] = true
	table.insert(self.Broke, Line)
end

function Watch.Around(self: Watch, Name: string, Inner: any, Key: string, Call: () -> ...any): ...any
	local Start = Latest(Inner:Look(Key))
	local Result = table.pack(pcall(Call))

	local Slot = Inner:Look(Key)
	local After = Latest(Slot)
	if After ~= nil and After ~= Start then
		local Prior = Before(Slot, After) or Start
		self:Judge(Name, Key, if Prior ~= nil then Prior.Text else nil, After.Text)
	end

	if not Result[1] then
		error(Result[2], 0)
	end
	return table.unpack(Result, 2, Result.n)
end

function Watch.Judge(self: Watch, Name: string, Key: string, Prior: string?, After: string?)
	if Prior == nil then
		return
	end
	if string.sub(Name, -#SUFFIX) ~= SUFFIX then
		if string.find(Prior, PARKED, 1, true) ~= nil then
			self:Legs(Name, Key, Prior, After)
		end
		return
	end
	if string.sub(Key, 1, #RESERVED) ~= RESERVED then
		self:Marker(Name, Key, Prior, After)
	end
end

function Watch.Legs(self: Watch, Name: string, Key: string, Prior: string, After: string?)
	local Now = Ops(After)
	local Where = `{Name}/{Key}`

	for Id, Leg in Ops(Prior) do
		local Tx, Gen = Leg.Tx, Leg.TxGen
		if type(Tx) ~= "string" or type(Gen) ~= "string" then
			continue
		end

		local Next = Now[Id]
		if Next ~= nil and Next.Tx ~= nil then
			continue
		end

		local Named = `{Tx}\0{Gen}`
		local Held = self.Outcomes[Named]
		if Held == nil then
			Held = { Committed = {}, Dropped = {} }
			self.Outcomes[Named] = Held
		end
		if Next ~= nil then
			Held.Committed[Where] = true
		else
			Held.Dropped[Where] = true
		end

		local Kept = next(Held.Committed)
		local Lost = next(Held.Dropped)
		if Kept ~= nil and Lost ~= nil then
			self:Say(`transaction '{Tx}' committed its leg on '{Kept}' and rolled back its leg on '{Lost}'`)
		end
	end
end

function Watch.Marker(self: Watch, Name: string, Key: string, Prior: string, After: string?)
	local Was = Json.Decode(Prior)
	if type(Was) ~= "table" or Was.Status ~= Transactions.COMMITTED or Was.Dead == true or type(Was.Gen) ~= "string" then
		return
	end

	local Gen: string = Was.Gen
	if not Aborted(Json.Decode(After), Gen) then
		return
	end

	for _, Store in self.Service.Stores do
		if string.sub(Store.Name, -#SUFFIX) == SUFFIX then
			continue
		end
		for Held, Slot in Store.Slots do
			local Text = Slot.Live
			if Text == nil or string.find(Text, PARKED, 1, true) == nil then
				continue
			end
			for _, Leg in Ops(Text) do
				if Leg.Tx == Key and Leg.TxGen == Gen and (Leg.TxHome == nil or Leg.TxHome == Name) then
					self:Say(`the marker of committed transaction '{Key}' went while its leg was still parked on '{Store.Name}/{Held}'`)
				end
			end
		end
	end
end

table.freeze(Watch)

return table.freeze({
	New = Watch.New,
})
