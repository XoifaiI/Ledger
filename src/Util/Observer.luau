--!strict
--!optimize 2

--[=[
	Observer: Sends each value to each listener.

	A listener runs immediately when you push a value, so a listener must not yield.
	Map, Filter and Changed each make a new stream from this one.
	Destroy marks each connection of the stream as gone. To disconnect one after that is therefore
	nothing, and not a fault.

	Return type: A table with New, which gives you a subject that you can push to.
	Example usage:
		local Observer = require("./Observer")
		local Stream = Observer.New()
		Stream:Subscribe(print)
		Stream:Push(1)
--]=]

local NoYield = require("./NoYield")

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Middleware<T, U> = (Value: T, Emit: (U) -> ()) -> ()

export type Observer<T> = {
	Subscribe: (self: Observer<T>, Listener: (T) -> ()) -> Connection,

	Use: <U>(self: Observer<T>, Middleware: Middleware<T, U>) -> Observer<U>,
	Map: <U>(self: Observer<T>, Transform: (T) -> U) -> Observer<U>,
	Filter: (self: Observer<T>, Predicate: (T) -> boolean) -> Observer<T>,
	Changed: (self: Observer<T>, Equals: ((T, T) -> boolean)?) -> Observer<T>,

	Destroy: (self: Observer<T>) -> (),
}

export type Subject<T> = Observer<T> & {
	Push: (self: Subject<T>, Value: T) -> (),
}

type Activate<T> = (Emit: (T) -> ()) -> (() -> ())?

type Node<T> = {
	Connected: boolean,
	Disconnect: (self: any) -> (),
	Listener: (T) -> (),
	Owner: Private<T>,
	Previous: Node<T>?,
	Next: Node<T>?,
}

type Private<T> = {
	Head: Node<T>?,
	Tail: Node<T>?,
	Activate: Activate<T>?,
	Teardown: (() -> ())?,
	Detached: boolean?,
	Said: number?,
}

local SLOW = 10

local Observer = {}
Observer.__index = Observer

local function ToPrivate<T>(self: any): Private<T>
	return self
end

local function Unlink<T>(self: Node<T>)
	if not self.Connected then
		return
	end
	self.Connected = false

	local Owner = self.Owner
	local Previous = self.Previous
	local Following = self.Next

	if Previous ~= nil then
		Previous.Next = Following
	else
		Owner.Head = Following
	end

	if Following ~= nil then
		Following.Previous = Previous
	else
		Owner.Tail = Previous
	end

	if Owner.Head == nil and Owner.Teardown then
		Owner.Teardown()
		Owner.Teardown = nil
	end
end

local function Carry<T>(self: Private<T>, Listener: (T) -> (), Value: T)
	local Done = false
	local Watch = task.delay(SLOW, function()
		local Now = os.clock()
		if Done or (self.Said ~= nil and Now - self.Said < SLOW) then
			return
		end

		self.Said = Now
		warn(`Ledger: an Observer listener has run for {SLOW} seconds without finishing. it holds a thread for as long as it runs, so one that never returns leaks a thread for every value pushed`)
	end)

	local Ok, Err = pcall(Listener, Value)
	Done = true
	if coroutine.status(Watch) == "suspended" then
		task.cancel(Watch)
	end

	if not Ok then
		warn(`Ledger: Observer listener errored: {Err}`)
	end
end

local function Deliver<T>(self: Private<T>, Value: T)
	local Node = self.Head
	local Last = self.Tail
	local Detached = self.Detached

	while Node ~= nil do
		local Following = if Node == Last then nil else Node.Next

		if Node.Connected then
			if Detached then
				task.spawn(Carry, self, Node.Listener, Value)
			else
				local Ok, Err = NoYield.Try(Node.Listener, Value)
				if not Ok then
					warn(`Ledger: Observer listener errored: {Err}`)
				end
			end
		end

		Node = Following
	end
end

local function Make<T>(Activate: Activate<T>?, Detached: boolean?): Observer<T>
	local Body: Private<T> = { Activate = Activate, Detached = Detached }

	return setmetatable(Body :: any, Observer) :: any
end

local function New<T>(Detached: boolean?): Subject<T>
	return Make(nil, Detached) :: any
end

function Observer.Subscribe<T>(self: Observer<T>, Listener: (T) -> ()): Connection
	local Private = ToPrivate(self)

	local Tail = Private.Tail
	local WasEmpty = Tail == nil
	assert(not WasEmpty or Private.Teardown == nil, "the stream is holding a teardown while nobody is listening")

	local Node: Node<T> = {
		Connected = true,
		Disconnect = Unlink,
		Listener = Listener,
		Owner = Private,
		Previous = Tail,
		Next = nil,
	}

	if Tail ~= nil then
		Tail.Next = Node
	else
		Private.Head = Node
	end
	Private.Tail = Node

	if WasEmpty and Private.Activate then
		Private.Teardown = Private.Activate(function(Value: T)
			Deliver(Private, Value)
		end)
	end

	return Node :: any
end

function Observer.Use<T, U>(self: Observer<T>, Middleware: Middleware<T, U>): Observer<U>
	return Make(function(Emit: (U) -> ())
		local Connection = self:Subscribe(function(Value: T)
			Middleware(Value, Emit)
		end)

		return function()
			Connection:Disconnect()
		end
	end, ToPrivate(self).Detached)
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

	local Node = Private.Head
	while Node ~= nil do
		Node.Connected = false
		Node = Node.Next
	end

	Private.Head = nil
	Private.Tail = nil
end

function Observer.Push<T>(self: Subject<T>, Value: T)
	Deliver(ToPrivate(self), Value)
end

table.freeze(Observer)

return table.freeze({
	New = New,
})
