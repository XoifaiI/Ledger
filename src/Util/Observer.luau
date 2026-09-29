--!strict
--!optimize 2

--[=[

	Observer: Sends each value to each listener.

	A listener runs the moment a value is pushed and must not yield: one that yields is stopped, and
	one that throws is reported, and neither stops the others. A detached stream runs each listener on
	a thread of its own instead, and says so once a listener has run for SLOW seconds. Use, Map, Filter
	and Changed each make a new stream from this one. From makes a stream that starts its source on the
	first subscriber and stops it after the last one leaves. Destroy stops the source and disconnects
	every listener. New takes no value to infer the element type from, so name it on the local that
	holds the stream.

	Return type: A table with New and From.
	Example usage:
		local Observer = require("./Observer")
		local Stream = Observer.New()
		Stream:Subscribe(print)
		Stream:Push(1)
--]=]

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
	local Owner, Previous, Following = self.Owner, self.Previous, self.Next
	if Previous then
		Previous.Next = Following
	else
		Owner.Head = Following
	end
	if Following then
		Following.Previous = Previous
	else
		Owner.Tail = Previous
	end
	local Teardown = Owner.Teardown
	if Owner.Head == nil and Teardown then
		Owner.Teardown = nil
		Teardown()
	end
end

local function Run<T>(Listener: (T) -> (), Value: T)
	local Thread = coroutine.create(Listener)
	local Ok, Err = coroutine.resume(Thread, Value)
	if not Ok then
		warn(`Ledger: an Observer listener threw: {Err}`)
	elseif coroutine.status(Thread) ~= "dead" then
		coroutine.close(Thread)
		warn("Ledger: an Observer listener yielded and was stopped. a listener runs the moment a value is pushed")
	end
end

local function Carry<T>(Owner: Private<T>, Listener: (T) -> (), Value: T)
	local Watch = task.delay(SLOW, function()
		local Now = os.clock()
		if Owner.Said and Now - Owner.Said < SLOW then
			return
		end
		Owner.Said = Now
		warn(`Ledger: an Observer listener has run for {SLOW} seconds. a listener that never returns leaks a thread for every value pushed`)
	end)
	local Ok, Err = pcall(Listener, Value)
	task.cancel(Watch)
	if not Ok then
		warn(`Ledger: an Observer listener threw: {Err}`)
	end
end

local function Deliver<T>(Owner: Private<T>, Value: T)
	local Entry, Last = Owner.Head, Owner.Tail
	while Entry do
		local Following = if Entry == Last then nil else Entry.Next
		if Entry.Connected then
			if Owner.Detached then
				task.spawn(Carry, Owner, Entry.Listener, Value)
			else
				Run(Entry.Listener, Value)
			end
		end
		Entry = Following
	end
end

local function Make<T>(Activate: Activate<T>?, Detached: boolean?): Observer<T>
	local Body: Private<T> = { Activate = Activate, Detached = Detached }
	return setmetatable(Body :: any, Observer) :: any
end

local function New(Detached: boolean?): Subject<any>
	return Make(nil, Detached) :: any
end

local function From<T>(Activate: (Emit: (T) -> ()) -> (() -> ())?, Detached: boolean?): Observer<T>
	return Make(Activate, Detached)
end

function Observer.Subscribe<T>(self: Observer<T>, Listener: (T) -> ()): Connection
	local Owner = ToPrivate(self)
	local Tail = Owner.Tail
	local Entry: Node<T> = {
		Connected = true,
		Disconnect = Unlink,
		Listener = Listener,
		Owner = Owner,
		Previous = Tail,
		Next = nil,
	}
	if Tail then
		Tail.Next = Entry
	else
		Owner.Head = Entry
	end
	Owner.Tail = Entry
	local Activate = Owner.Activate
	if Tail == nil and Activate then
		Owner.Teardown = Activate(function(Value: T)
			Deliver(Owner, Value)
		end)
	end
	return Entry :: any
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
	local Last: { Value: T }? = nil
	return self:Use(function(Value: T, Emit: (T) -> ())
		if Last and (if Equals then Equals(Last.Value, Value) else Last.Value == Value) then
			return
		end
		Last = { Value = Value }
		Emit(Value)
	end)
end

function Observer.Destroy<T>(self: Observer<T>)
	local Owner = ToPrivate(self)
	local Teardown = Owner.Teardown
	Owner.Teardown = nil
	if Teardown then
		Teardown()
	end
	local Entry = Owner.Head
	while Entry do
		Entry.Connected = false
		Entry = Entry.Next
	end
	Owner.Head = nil
	Owner.Tail = nil
end

function Observer.Push<T>(self: Subject<T>, Value: T)
	Deliver(ToPrivate(self), Value)
end

table.freeze(Observer)

return table.freeze({
	New = New,
	From = From,
})
