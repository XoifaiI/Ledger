--!strict
--!optimize 2

--[=[

	Fault: The failures a case asks a datastore for, and which call each one takes.

	A fault names the call it watches and what happens to it. Dropped never reached the service.
	Swallowed landed and lost its answer. Stalled arrives late. Meddled goes through after running
	something first. Stale is a read that answers the version before the newest, or nothing when
	the key has only one. An ordinal aims one at the Nth matching call.

	Wrap puts a memory hook behind the faults a case adds to it, over its datastores and its
	MemoryStore maps alike. The store Ledger is handed cannot tell it is being lied to. A map and a
	datastore share method names, so a fault meant for one names it with OnStore. A Watch passed to
	Wrap judges every datastore write as it lands, faulted or not.

	Return type: A table with Wrap, On and the five builders. The types are Spec, Effect and Faulted.
	Example usage:
		local Hook = Fault.Wrap(Memory.New(Turn, nil, Service), Turn)
		Hook.Fail(Fault.Updates():OnKey("42"):After(2):Swallow())
--]=]

local Engine = require("../../src/Util/Engine")
local Memory = require("../../src/Hooks/Memory")
local Watch = require("./Watch")

export type Effect = "Drop" | "Swallow" | "Stall" | "Meddle" | "Stale"

local DROP: Effect = "Drop"
local SWALLOW: Effect = "Swallow"
local STALL: Effect = "Stall"
local MEDDLE: Effect = "Meddle"
local STALE: Effect = "Stale"

local READ = "GetAsync"
local SET = "SetAsync"
local UPDATE = "UpdateAsync"
local REMOVE = "RemoveAsync"
local VERSION = "GetVersionAsync"
local VERSIONS = "ListVersionsAsync"
local LISTED = "ListKeysAsync"

local STORE_METHODS: { string } = { READ, UPDATE, REMOVE, VERSION, VERSIONS, LISTED }
local MAP_METHODS: { string } = { READ, SET, UPDATE, REMOVE }
local METHODS: { string } = { READ, SET, UPDATE, REMOVE, VERSION, VERSIONS, LISTED }
local WRITES: { [string]: boolean } = { [UPDATE] = true, [REMOVE] = true }

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
	Stale: (self: Spec) -> Spec,

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

export type Faulted = Memory.Memory & {
	read Fail: (Spec: Spec) -> Spec,
	read Clear: () -> (),
}

local Spec = {} :: SpecImpl
Spec.__index = Spec

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

local function Fire(Held: Spec, Scheduler: Engine.Scheduler, Inner: any, Method: string, ...: any): ...any
	Held.Fired += 1

	if Held.Effect == DROP then
		error(DOWN, 0)
	end
	if Held.Effect == STALL then
		Scheduler.Wait(Held.Seconds)
		return Inner[Method](Inner, ...)
	end
	if Held.Effect == MEDDLE then
		local Body = Held.Body
		if Body ~= nil then
			Body()
		end
		return Inner[Method](Inner, ...)
	end
	if Held.Effect == STALE then
		local Look = Inner.Look
		assert(Look ~= nil, "a stale read needs the fake datastore's versions, and a map keeps none")
		local Key = tostring((...))
		local Slot = (Look :: any)(Inner, Key)
		local Entries = if Slot == nil then {} else Slot.Entries
		local Prior = Entries[#Entries - 1]
		if Prior == nil or Prior.Text == nil then
			Inner:Reach(Enum.DataStoreRequestType.GetAsync)
			return nil, nil
		end
		return Inner:GetVersionAsync(Key, Prior.Label)
	end

	Inner[Method](Inner, ...)
	error(SWALLOWED, 0)
end

local function Proxy(Specs: { Spec }, Scheduler: Engine.Scheduler, Name: string, Inner: any, Methods: { string }, Watching: Watch.Watch?): any
	local Held = {}

	for _, Method in Methods do
		Held[Method] = function(_: any, ...: any): ...any
			local Key = if Method == LISTED then "" else tostring((...))
			local Firing = Chosen(Specs, Name, Method, Key)
			local Given = table.pack(...)

			local function Call(): ...any
				if Firing == nil then
					return Inner[Method](Inner, table.unpack(Given, 1, Given.n))
				end
				return Fire(Firing, Scheduler, Inner, Method, table.unpack(Given, 1, Given.n))
			end

			if Watching ~= nil and WRITES[Method] then
				return Watching:Around(Name, Inner, Key, Call)
			end
			return Call()
		end
	end

	return Held :: any
end

local function On(Method: string): Spec
	assert(table.find(METHODS, Method) ~= nil, `a case cannot fault '{Method}', it is not a datastore call`)

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

local function Wrap(Hook: Memory.Memory, Scheduler: Engine.Scheduler, Watching: Watch.Watch?): Faulted
	local Specs: { Spec } = {}
	local Cache: ((Name: string) -> Engine.Map)? = (Hook :: any).Cache

	return table.freeze({
		Service = Hook.Service,
		Budget = Hook.Budget,

		Open = function(Name: string): Engine.Store
			return Proxy(Specs, Scheduler, Name, Hook.Open(Name), STORE_METHODS, Watching)
		end,

		Cache = if Cache == nil
			then nil
			else function(Name: string): Engine.Map
				return Proxy(Specs, Scheduler, Name, Cache(Name), MAP_METHODS)
			end,

		Fail = function(Given: Spec): Spec
			table.insert(Specs, Given)
			return Given
		end,

		Clear = function()
			table.clear(Specs)
		end,
	}) :: any
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

function Spec.Stale(self: Spec): Spec
	assert(self.Method == READ, "only a read can answer stale, a write either lands or does not")
	self.Effect = STALE
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

return table.freeze({
	Wrap = Wrap,

	On = On,
	Reads = function(): Spec
		return On(READ)
	end,
	Sets = function(): Spec
		return On(SET)
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
})
