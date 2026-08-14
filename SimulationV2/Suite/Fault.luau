--!strict
--!optimize 2

--[=[
	Fault: One named request that does not go the way the caller asked.

	The fuzzer breaks requests at random. A case wants the opposite: this call, on this key, breaks
	this way, every time. A fault says which call it watches, when it fires, and what it does.
	A dropped request never arrived. A swallowed one landed and its answer was lost. A stalled one
	arrives late, so other callers pile up behind it.

	Return type: A table with On, Reads, Updates, Removes, Versions, Lists and Wrap.
	Example usage:
		Store:Fault(Fault.Updates():OnKey("b"):After(1))
--]=]

local Board = require("../Board")

export type Effect = "Drop" | "Swallow" | "Stall" | "Pass"

type SpecImpl = {
	__index: SpecImpl,

	OnKey: (self: Spec, Key: string) -> Spec,
	Only: (self: Spec, Nth: number) -> Spec,
	After: (self: Spec, Count: number) -> Spec,
	Swallow: (self: Spec) -> Spec,
	Stall: (self: Spec, Seconds: number) -> Spec,
	Meddle: (self: Spec, Body: () -> ()) -> Spec
}

export type Spec = setmetatable<{
	Method: string,
	Key: string?,
	Nth: number?,
	Past: number?,
	Effect: Effect,
	Seconds: number,
	Before: (() -> ())?,
	Count: number,
	Fired: number
}, SpecImpl>

local DROP: Effect = "Drop"
local SWALLOW: Effect = "Swallow"
local STALL: Effect = "Stall"
local PASS: Effect = "Pass"

local READ = "GetAsync"
local UPDATE = "UpdateAsync"
local REMOVE = "RemoveAsync"
local VERSION = "GetVersionAsync"
local VERSIONS = "ListVersionsAsync"
local LISTED = "ListKeysAsync"

local Spec = {} :: SpecImpl
Spec.__index = Spec

local function Matches(Spec: Spec, Method: string, Key: string): boolean
	if Spec.Method ~= Method then
		return false
	end
	return Spec.Key == nil or Spec.Key == Key
end

local function Due(Spec: Spec): boolean
	if Spec.Nth ~= nil then
		return Spec.Count == Spec.Nth
	end
	if Spec.Past ~= nil then
		return Spec.Count > Spec.Past
	end
	return true
end

local function Chosen(Specs: { Spec }, Method: string, Key: string): Spec?
	local Firing: Spec? = nil
	for _, Held in Specs do
		if not Matches(Held, Method, Key) then
			continue
		end

		Held.Count += 1
		if Firing == nil and Due(Held) then
			Firing = Held
		end
	end
	return Firing
end

local function On(Method: string): Spec
	return setmetatable({
		Method = Method,
		Key = nil,
		Nth = nil,
		Past = nil,
		Effect = DROP,
		Seconds = 0,
		Before = nil,
		Count = 0,
		Fired = 0
	}, Spec) :: any
end

local function Reads(): Spec
	return On(READ)
end

local function Updates(): Spec
	return On(UPDATE)
end

local function Removes(): Spec
	return On(REMOVE)
end

local function Versions(): Spec
	return On(VERSION)
end

local function Lists(): Spec
	return On(LISTED)
end

local function Wrap(Inner: any, Specs: { Spec }): any
	local Proxy = {}

	local function Call(Method: string, Key: string, Run: () -> ...any): ...any
		local Firing = Chosen(Specs, Method, Key)
		if Firing == nil then
			return Run()
		end

		Firing.Fired += 1
		local Before = Firing.Before
		if Before ~= nil then
			Before()
		end

		if Firing.Effect == PASS then
			return Run()
		end
		if Firing.Effect == DROP then
			error(Board.DOWN, 0)
		end

		if Firing.Effect == STALL then
			task.wait(Firing.Seconds)
			return Run()
		end

		Run()
		error(Board.SWALLOWED, 0)
	end

	function Proxy.GetAsync(_: any, Key: string): ...any
		return Call(READ, Key, function(): ...any
			return Inner:GetAsync(Key)
		end)
	end

	function Proxy.UpdateAsync(_: any, Key: string, Transform: any): ...any
		return Call(UPDATE, Key, function(): ...any
			return Inner:UpdateAsync(Key, Transform)
		end)
	end

	function Proxy.RemoveAsync(_: any, Key: string): ...any
		return Call(REMOVE, Key, function(): ...any
			return Inner:RemoveAsync(Key)
		end)
	end

	function Proxy.GetVersionAsync(_: any, Key: string, Version: string): ...any
		return Call(VERSION, Key, function(): ...any
			return Inner:GetVersionAsync(Key, Version)
		end)
	end

	function Proxy.ListVersionsAsync(_: any, Key: string, Direction: any, Least: any, Most: any, Size: any): ...any
		return Call(VERSIONS, Key, function(): ...any
			return Inner:ListVersionsAsync(Key, Direction, Least, Most, Size)
		end)
	end

	function Proxy.ListKeysAsync(_: any, Prefix: any, Size: any, Cursor: any, Hiding: any): ...any
		return Call(LISTED, "", function(): ...any
			return Inner:ListKeysAsync(Prefix, Size, Cursor, Hiding)
		end)
	end

	return Proxy
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
	self.Effect = PASS
	self.Before = Body
	return self
end

table.freeze(Spec)

return table.freeze({
	On = On,
	Reads = Reads,
	Updates = Updates,
	Removes = Removes,
	Versions = Versions,
	Lists = Lists,
	Wrap = Wrap,

	DROP = DROP,
	SWALLOW = SWALLOW,
	STALL = STALL,
	PASS = PASS
})
