--!strict
--!optimize 2

--[=[
	Observer: Sends each value to each listener, which must not yield. From links the first subscriber before starting
	its source, so values during the start find it, and stops it after the last leaves. A throwing start's subscriber
	is dropped, then the next Subscribe restarts it; a throwing stop leaves it stopped. FromLatest gives late listeners
	the last value, deferred.

	Return type: A table with New, which gives you a subject that you can push to, From and FromLatest.
	Example usage:
		local Observer = require("./Observer")
		local Stream = Observer.New()
		Stream:Subscribe(print)
		Stream:Push(1)
--]=]

local Threads = require("./Threads")

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

type Starting<T> = {
	read Thread: thread,
	read Node: Node<T>,
	read Run: () -> (),
}

type Latest<T> = {
	read Value: T,
}

type Options = {
	read Detached: boolean?,
	read Keeps: boolean?,
}

type Private<T> = {
	Head: Node<T>?,
	Tail: Node<T>?,
	Activate: Activate<T>?,
	Teardown: (() -> ())?,
	IsStarted: boolean?,
	Starting: Starting<T>?,
	Detached: boolean?,
	Said: number?,
	Keeps: boolean?,
	Latest: Latest<T>?,
	Sent: number,
}

local SLOW = 10
local NextCycle = 0

local Observer = {}
Observer.__index = Observer

local function ToPrivate<T>(self: any): Private<T>
	return self
end

local function Stop<T>(Private: Private<T>)
	Private.Latest = nil
	if not Private.IsStarted then
		return
	end
	local Teardown = Private.Teardown
	Private.IsStarted = false
	Private.Teardown = nil
	if Teardown ~= nil then
		Teardown()
	end
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

	if Owner.Head == nil then
		Stop(Owner)
	end
end

local function DropFailedStart<T>(Private: Private<T>)
	local Starting = Private.Starting
	if Starting == nil or Threads.HasFrame(Starting.Thread, Starting.Run) then
		return
	end
	Private.Starting = nil
	Unlink(Starting.Node)
end

local function Threw(Err: any)
	warn(`Ledger: Observer listener errored: {Err}`)
end

local function Carry<T>(self: Private<T>, Listener: (T) -> (), Value: T)
	local Done = false
	local Watch = Threads.Delay(SLOW, function()
		local Now = Threads.Now()
		if Done or (self.Said ~= nil and Now - self.Said < SLOW) then
			return
		end

		self.Said = Now
		warn(
			`Ledger: an Observer listener has run for {SLOW} seconds without finishing. `
				.. "A listener that never returns leaks a thread for every value pushed."
		)
	end)

	local Ok, Err = pcall(Listener, Value)
	Done = true
	Threads.Cancel(Watch)

	if not Ok then
		Threw(Err)
	end
end

local function Notify<T>(self: Private<T>, Node: Node<T>, Value: T)
	if not Node.Connected then
		return
	end
	if self.Detached then
		Threads.Scheduler().Spawn(Carry, self, Node.Listener, Value)
		return
	end
	local Ok, Err = NoYield.Try(Node.Listener, Value)
	if not Ok then
		Threw(Err)
	end
end

local function Deliver<T>(self: Private<T>, Value: T)
	DropFailedStart(self)
	if self.Keeps then
		self.Latest = { Value = Value }
		self.Sent += 1
	end
	local Node = self.Head
	local Last = self.Tail

	while Node ~= nil do
		local Following = if Node == Last then nil else Node.Next
		Notify(self, Node, Value)
		Node = Following
	end
end

local function Replay<T>(self: Private<T>, Node: Node<T>)
	local Latest = self.Latest
	if Latest == nil then
		return
	end
	local SentBefore = self.Sent
	Threads.Delay(NextCycle, function()
		if self.Sent == SentBefore then
			Notify(self, Node, Latest.Value)
		end
	end)
end

local function Link<T>(Private: Private<T>, Listener: (T) -> ()): Node<T>
	local Tail = Private.Tail
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
	return Node
end

local function Start<T>(Private: Private<T>, Node: Node<T>, Activate: Activate<T>)
	local Starting: Starting<T> = {
		Thread = coroutine.running(),
		Node = Node,
		Run = function()
			Private.Teardown = Activate(function(Value: T)
				Deliver(Private, Value)
			end)
		end,
	}
	Private.Starting = Starting
	Starting.Run()
	Private.Starting = nil
	Private.IsStarted = true
	if Private.Head == nil then
		Stop(Private)
	end
end

local function Make<T>(Activate: Activate<T>?, Options: Options): Observer<T>
	local Body: Private<T> = { Activate = Activate, Detached = Options.Detached, Keeps = Options.Keeps, Sent = 0 }

	return setmetatable(Body :: any, Observer) :: any
end

local function New<T>(Detached: boolean?): Subject<T>
	return Make(nil, { Detached = Detached }) :: any
end

local function From<T>(Activate: (Emit: (T) -> ()) -> (() -> ())?, Detached: boolean?): Observer<T>
	return Make(Activate, { Detached = Detached })
end

local function FromLatest<T>(Activate: (Emit: (T) -> ()) -> (() -> ())?): Observer<T>
	return Make(Activate, { Keeps = true })
end

function Observer.Subscribe<T>(self: Observer<T>, Listener: (T) -> ()): Connection
	local Private = ToPrivate(self)
	DropFailedStart(Private)

	local Node = Link(Private, Listener)
	local Activate = Private.Activate
	if Activate ~= nil and not Private.IsStarted and Private.Starting == nil then
		Start(Private, Node, Activate)
	else
		Replay(Private, Node)
	end

	return Node :: any
end

function Observer.Use<T, U>(self: Observer<T>, Middleware: Middleware<T, U>): Observer<U>
	local Source = ToPrivate(self)
	return Make(function(Emit: (U) -> ())
		local Connection = self:Subscribe(function(Value: T)
			Middleware(Value, Emit)
		end)

		return function()
			Connection:Disconnect()
		end
	end, { Detached = Source.Detached, Keeps = Source.Keeps })
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

	Stop(Private)

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
	From = From,
	FromLatest = FromLatest,
})
