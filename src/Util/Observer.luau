--!strict
--!optimize 2

-- a value stream you push to and subscribe to, listeners run inline so they must not yield

local NoYield = require("./NoYield")

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> ()
}

export type Middleware<T, U> = (Value: T, Emit: (U) -> ()) -> ()

export type Observer<T> = {
	Subscribe: (self: Observer<T>, Listener: (T) -> ()) -> Connection,

	Use: <U>(self: Observer<T>, Middleware: Middleware<T, U>) -> Observer<U>,
	Map: <U>(self: Observer<T>, Transform: (T) -> U) -> Observer<U>,
	Filter: (self: Observer<T>, Predicate: (T) -> boolean) -> Observer<T>,
	Changed: (self: Observer<T>, Equals: ((T, T) -> boolean)?) -> Observer<T>,

	Destroy: (self: Observer<T>) -> ()
}

export type Subject<T> = Observer<T> & {
	Push: (self: Subject<T>, Value: T) -> ()
}

type Activate<T> = (Emit: (T) -> ()) -> (() -> ())?

type Private<T> = {
	Listeners: { [Connection]: (T) -> () },
	Activate: Activate<T>?,
	Teardown: (() -> ())?
}

local Observer = {}
Observer.__index = Observer

local function ToPrivate<T>(self: any): Private<T>
	return self
end

local function Deliver<T>(self: Private<T>, Value: T)
	local Snapshot: { Connection } = {}
	for Link in self.Listeners do
		table.insert(Snapshot, Link)
	end

	for _, Link in Snapshot do
		local Listener = self.Listeners[Link]
		if Listener == nil then
			continue
		end

		local Ok, Err = pcall(NoYield, Listener, Value)
		if not Ok then
			warn(`Observer listener errored: {Err}`)
		end
	end
end

local function Make<T>(Activate: Activate<T>?): Observer<T>
	local Body: Private<T> = {
		Listeners = {},
		Activate = Activate
	}

	return setmetatable(Body :: any, Observer) :: any
end

function Observer.Subscribe<T>(self: Observer<T>, Listener: (T) -> ()): Connection
	local Private = ToPrivate(self)

	local Connection: Connection
	Connection = {
		Connected = true,
		Disconnect = function(Self: Connection)
			if not Self.Connected then
				return
			end

			Self.Connected = false
			assert(Private.Listeners[Connection] ~= nil, "a connection disconnected while the stream had already forgotten it")
			Private.Listeners[Connection] = nil

			if next(Private.Listeners) == nil and Private.Teardown then
				Private.Teardown()
				Private.Teardown = nil
			end
		end
	}

	local WasEmpty = next(Private.Listeners) == nil
	assert(not WasEmpty or Private.Teardown == nil, "the stream is holding a teardown while nobody is listening")
	Private.Listeners[Connection] = Listener

	if WasEmpty and Private.Activate then
		Private.Teardown = Private.Activate(function(Value: T)
			Deliver(Private, Value)
		end)
	end

	return Connection
end

function Observer.Use<T, U>(self: Observer<T>, Middleware: Middleware<T, U>): Observer<U>
	return Make(function(Emit: (U) -> ())
		local Connection = self:Subscribe(function(Value: T)
			Middleware(Value, Emit)
		end)

		return function()
			Connection:Disconnect()
		end
	end)
end

function Observer.Map<T, U>(self: Observer<T>, Transform: (T) -> U): Observer<U>
	return self:Use(function(Value: T, Emit: (U) -> ())
		Emit(Transform(Value))
	end)
end

function Observer.Filter<T>(self: Observer<T>, Predicate: (T) -> boolean): Observer<T>
	return self:Use(function(Value: T, Emit: (T) -> ())
		if Predicate(Value) then
			Emit(Value)
		end
	end)
end

function Observer.Changed<T>(self: Observer<T>, Equals: ((T, T) -> boolean)?): Observer<T>
	local Last: T?
	local HasLast = false

	return self:Use(function(Value: T, Emit: (T) -> ())
		if HasLast then
			local Same = if Equals then Equals(Last :: T, Value) else Value == Last
			if Same then
				return
			end
		end

		HasLast = true
		Last = Value
		Emit(Value)
	end)
end

function Observer.Destroy<T>(self: Observer<T>)
	local Private = ToPrivate(self)

	if Private.Teardown then
		Private.Teardown()
		Private.Teardown = nil
	end

	table.clear(Private.Listeners)
end

function Observer.Push<T>(self: Subject<T>, Value: T)
	Deliver(ToPrivate(self), Value)
end

local function New<T>(): Subject<T>
	return Make() :: any
end

table.freeze(Observer)
return table.freeze({
	New = New
})
