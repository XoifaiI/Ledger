--!strict
--!optimize 2

--[=[
	Memory: The datastore Ledger writes to in a test, and the faults a test wants it to have.

	It is the mock behind the shape the real one takes, so a store cannot tell which it was handed,
	and every wait goes to the scheduler it was given.
	A fault names the call it watches and what happens to it. A dropped one never reached the
	datastore. A swallowed one landed and its answer was lost, which a caller cannot tell from one
	that never happened at all. A stalled one arrives late, so other callers pile up behind it. A
	meddled one goes through untouched but runs something first, which is how a test puts another
	server's write in the middle of this one.
	A fault fires on every call it matches unless it is given an ordinal, so a test can aim at the
	third write of a protocol and leave the rest alone. That is the difference between a fault a
	person writes and one a fuzzer rolls.
	Faults belong to the hook and not to the data, so two hooks over one service are two servers on one
	datastore and only one of them is broken. That is the only way to say it: a store name cannot,
	since two servers share it.

	Return type: A table with New, On, the five builders, DOWN and SWALLOWED. The types are Memory, Spec and Effect.
	Example usage:
		local Held = Memory.New(Turn)
		Held.Fail(Memory.Updates():OnKey("42"):After(2):Swallow())
		local Beside = Memory.New(Turn, nil, Held.Service)
--]=]

local Engine = require("../Util/Engine")
local Mock = require("../Mock")
local Roblox = require("../Schedulers/Roblox")

export type Effect = "Drop" | "Swallow" | "Stall" | "Meddle"

local DROP: Effect = "Drop"
local SWALLOW: Effect = "Swallow"
local STALL: Effect = "Stall"
local MEDDLE: Effect = "Meddle"

local READ = "GetAsync"
local UPDATE = "UpdateAsync"
local REMOVE = "RemoveAsync"
local VERSION = "GetVersionAsync"
local VERSIONS = "ListVersionsAsync"
local LISTED = "ListKeysAsync"

local METHODS: { string } = { READ, UPDATE, REMOVE, VERSION, VERSIONS, LISTED }

local DOWN = "Ledger memory hook: the request never reached the datastore"
local SWALLOWED = "Ledger memory hook: the write landed and the answer was lost"

type SpecImpl = {
	__index: SpecImpl,

	OnStore: (self: Spec, Name: string) -> Spec,
	OnKey: (self: Spec, Key: string) -> Spec,
	Only: (self: Spec, Nth: number) -> Spec,
	After: (self: Spec, Count: number) -> Spec,
	Swallow: (self: Spec) -> Spec,
	Stall: (self: Spec, Seconds: number) -> Spec,
	Meddle: (self: Spec, Body: () -> ()) -> Spec,

	Matches: (self: Spec, Name: string, Method: string, Key: string) -> boolean,
	Due: (self: Spec) -> boolean,
}

export type Spec = setmetatable<{
	Method: string,
	Store: string?,
	Key: string?,
	Nth: number?,
	Past: number?,
	Effect: Effect,
	Seconds: number,
	Body: (() -> ())?,
	Count: number,
	Fired: number,
}, SpecImpl>

export type Memory = {
	read Open: (Name: string) -> Engine.Store,
	read Budget: (Kind: Enum.DataStoreRequestType) -> number,
	read Service: Mock.Service,
	read Fail: (Spec: Spec) -> Spec,
	read Clear: () -> (),
}

local Spec = {} :: SpecImpl
Spec.__index = Spec

local function On(Method: string): Spec
	assert(table.find(METHODS, Method) ~= nil, `a memory hook cannot fault '{Method}', it is not a datastore call`)

	return setmetatable({
		Method = Method,
		Store = nil,
		Key = nil,
		Nth = nil,
		Past = nil,
		Effect = DROP,
		Seconds = 0,
		Body = nil,
		Count = 0,
		Fired = 0,
	}, Spec) :: any
end

function Spec.OnStore(self: Spec, Name: string): Spec
	self.Store = Name
	return self
end

function Spec.OnKey(self: Spec, Key: string): Spec
	self.Key = Key
	return self
end

function Spec.Only(self: Spec, Nth: number): Spec
	assert(Nth >= 1, "a fault that fires on call zero never fires")
	self.Nth = Nth
	return self
end

function Spec.After(self: Spec, Count: number): Spec
	assert(Count >= 0, "a fault cannot let a negative number of calls through first")
	self.Past = Count
	return self
end

function Spec.Swallow(self: Spec): Spec
	self.Effect = SWALLOW
	return self
end

function Spec.Stall(self: Spec, Seconds: number): Spec
	assert(Seconds > 0, "a stall of no time is not a stall")
	self.Effect = STALL
	self.Seconds = Seconds
	return self
end

function Spec.Meddle(self: Spec, Body: () -> ()): Spec
	self.Effect = MEDDLE
	self.Body = Body
	return self
end

function Spec.Matches(self: Spec, Name: string, Method: string, Key: string): boolean
	if self.Method ~= Method then
		return false
	end
	if self.Store ~= nil and self.Store ~= Name then
		return false
	end
	return self.Key == nil or self.Key == Key
end

function Spec.Due(self: Spec): boolean
	if self.Nth ~= nil then
		return self.Count == self.Nth
	end
	if self.Past ~= nil then
		return self.Count > self.Past
	end
	return true
end

table.freeze(Spec)

local function Chosen(Specs: { Spec }, Name: string, Method: string, Key: string): Spec?
	local Firing: Spec? = nil
	for _, Held in Specs do
		if not Held:Matches(Name, Method, Key) then
			continue
		end

		Held.Count += 1
		if Firing == nil and Held:Due() then
			Firing = Held
		end
	end
	return Firing
end

local function New(Scheduler: Engine.Scheduler?, Options: Mock.Options?, Shared: Mock.Service?): Memory
	local Turn = Scheduler or Roblox.New()
	local Service = Shared or Mock.New(Options, Turn)
	local Specs: { Spec } = {}

	local function Wrap(Name: string, Inner: any): Engine.Store
		local Proxy = {}

		for _, Method in METHODS do
			Proxy[Method] = function(_: any, ...: any): ...any
				local Key = if Method == LISTED then "" else tostring((...))
				local Firing = Chosen(Specs, Name, Method, Key)

				if Firing == nil then
					return Inner[Method](Inner, ...)
				end

				Firing.Fired += 1
				if Firing.Effect == DROP then
					error(DOWN, 0)
				end
				if Firing.Effect == STALL then
					Turn.Wait(Firing.Seconds)
					return Inner[Method](Inner, ...)
				end
				if Firing.Effect == MEDDLE then
					local Body = Firing.Body
					if Body ~= nil then
						Body()
					end
					return Inner[Method](Inner, ...)
				end

				Inner[Method](Inner, ...)
				error(SWALLOWED, 0)
			end
		end

		return Proxy :: any
	end

	local Held = {
		Service = Service,
	} :: any

	Held.Open = function(Name: string): Engine.Store
		return Wrap(Name, Service:GetDataStore(Name))
	end

	Held.Budget = function(Kind: Enum.DataStoreRequestType): number
		return Service:GetRequestBudgetForRequestType(Kind)
	end

	Held.Fail = function(Given: Spec): Spec
		table.insert(Specs, Given)
		return Given
	end

	Held.Clear = function()
		table.clear(Specs)
	end

	return Held :: Memory
end

return table.freeze({
	New = New,

	On = On,
	Reads = function(): Spec
		return On(READ)
	end,
	Updates = function(): Spec
		return On(UPDATE)
	end,
	Removes = function(): Spec
		return On(REMOVE)
	end,
	Versions = function(): Spec
		return On(VERSION)
	end,
	Lists = function(): Spec
		return On(LISTED)
	end,

	DOWN = DOWN,
	SWALLOWED = SWALLOWED,
})
