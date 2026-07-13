--!strict
--!optimize 2

--[=[
    Observer: reactive stream you pipe through map filter copy etc and subscribe to, sourced from signals values or manual pushes

    listeners must not yield: delivery runs inline on the pusher's thread (a data session notifies
    mid operation, a net event delivers mid receive), so every listener runs through NoYield and a
    yield raises loudly instead of suspending the emitter. spawn a thread inside the listener for
    async work.

    Return type: frozen table { New, Value, From, Merge, Source }
    Example usage:
        local Observer = require("./Observer")
        local Subject = Observer.New()
        Subject:Subscribe(function(Value)
            print(Value)
        end)
        Subject:Push(10)
--]=]

local Deconstructor = require("./Deconstructor")
local FutureModule = require("./Future")
local NoYield = require("./NoYield")
local TableUtil = require("./TableUtil")
local Threads = require("./Threads")

type Future<T> = FutureModule.Future<T>

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Middleware<T, U> = (Value: T, Emit: (U) -> ()) -> ()

export type Observer<T> = {
	Subscribe: (self: Observer<T>, Listener: (T) -> ()) -> Connection,
	Once: (self: Observer<T>, Listener: (T) -> ()) -> Connection,
	Next: (self: Observer<T>) -> Future<T>,

	Use: <U>(self: Observer<T>, Middleware: Middleware<T, U>) -> Observer<U>,
	Map: <U>(self: Observer<T>, Transform: (T) -> U) -> Observer<U>,
	Filter: (self: Observer<T>, Predicate: (T) -> boolean) -> Observer<T>,
	Copy: (self: Observer<T>) -> Observer<T>,
	Redact: (self: Observer<T>, Fields: {string}) -> Observer<T>,
	Changed: (self: Observer<T>, Equals: ((T, T) -> boolean)?) -> Observer<T>,
	Debounce: (self: Observer<T>, Seconds: number) -> Observer<T>,

	Destroy: (self: Observer<T>) -> (),
}

export type Subject<T> = Observer<T> & {
	Push: (self: Subject<T>, Value: T) -> (),
}

export type Value<T> = Observer<T> & {
	Set: (self: Value<T>, NewValue: T) -> (),
	Get: (self: Value<T>) -> T,
}

type Activate<T> = (Emit: (T) -> ()) -> (() -> ())?

type Private<T> = {
	Listeners: { [Connection]: (T) -> () },
	Activate: Activate<T>?,
	Teardown: (() -> ())?,

	HasValue: boolean,
	Current: T?,
}

local Observer = {}
Observer.__index = Observer

local function ToPrivate<T>(self: any): Private<T>
	return self
end

local function Deliver<T>(self: Private<T>, Value: T)
	local Snapshot: {(T) -> ()} = {}
	for _, Listener in self.Listeners do
		table.insert(Snapshot, Listener)
	end

	for _, Listener in Snapshot do
		local Ok, Err = pcall(NoYield, Listener, Value)
		if not Ok then
			warn(`Observer listener errored: {Err}`)
		end
	end
end

local function Make<T>(Activate: Activate<T>?): Observer<T>
	local Body: Private<T> = {
		Listeners = {},
		Activate = Activate,
		HasValue = false,
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
			Private.Listeners[Connection] = nil

			if next(Private.Listeners) == nil and Private.Teardown then
				Private.Teardown()
				Private.Teardown = nil
			end
		end,
	}

	local WasEmpty = next(Private.Listeners) == nil
	Private.Listeners[Connection] = Listener

	if WasEmpty and Private.Activate then
		Private.Teardown = Private.Activate(function(Value: T)
			Deliver(Private, Value)
		end)
	end

	if Private.HasValue then
		local Ok, Err = pcall(NoYield, Listener, Private.Current :: T)
		if not Ok then
			warn(`Observer listener errored: {Err}`)
		end
	end

	return Connection
end

function Observer.Once<T>(self: Observer<T>, Listener: (T) -> ()): Connection
	local Connection: Connection
	local Done = false

	Connection = self:Subscribe(function(Value: T)
		if Done then
			return
		end
		Done = true

		if Connection then
			Connection:Disconnect()
		end
		Listener(Value)
	end)

	if Done then
		Connection:Disconnect()
	end

	return Connection
end

function Observer.Next<T>(self: Observer<T>): Future<T>
	return FutureModule.New(function(): T
		local Caller = coroutine.running()
		local Captured: T
		local Delivered = false

		self:Once(function(Value: T)
			Captured = Value
			Delivered = true
			Threads.Resume(Caller, Value)
		end)

		if Delivered then
			return Captured
		end

		return coroutine.yield()
	end)
end

function Observer.Use<T, U>(self: Observer<T>, Middleware: Middleware<T, U>): Observer<U>
	return Make(function(Emit: (U) -> ())
		local Connection = self:Subscribe(function(Value: T)
			Middleware(Value, Emit)
		end)

		return Deconstructor(Connection)
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

function Observer.Copy<T>(self: Observer<T>): Observer<T>
	return self:Use(function(Value: T, Emit: (T) -> ())
		Emit(TableUtil.DeepCopy(Value))
	end)
end

function Observer.Redact<T>(self: Observer<T>, Fields: {string}): Observer<T>
	return self:Use(function(Value: T, Emit: (T) -> ())
		Emit(TableUtil.Without(Value, Fields))
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

function Observer.Debounce<T>(self: Observer<T>, Seconds: number): Observer<T>
	local Scheduled: thread?

	return self:Use(function(Value: T, Emit: (T) -> ())
		if Scheduled then
			task.cancel(Scheduled)
		end

		Scheduled = task.delay(Seconds, function()
			Scheduled = nil
			Emit(Value)
		end)
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

function Observer.Set<T>(self: Value<T>, NewValue: T)
	local Private = ToPrivate(self)
	Private.Current = NewValue
	Private.HasValue = true

	Deliver(Private, NewValue)
end

function Observer.Get<T>(self: Value<T>): T
	return ToPrivate(self).Current :: T
end

local function NewSubject<T>(): Subject<T>
	return Make() :: any
end

local function NewValue<T>(Initial: T): Value<T>
	local self = Make()
	local Private = ToPrivate(self)
	Private.Current = Initial
	Private.HasValue = true

	return self :: any
end

local function FromSignal<T>(Signal: RBXScriptSignal): Observer<T>
	return Make(function(Emit: (T) -> ())
		local Connection = Signal:Connect(function(...)
			Emit(... :: any)
		end)

		return Deconstructor(Connection)
	end)
end

local function Merge<T>(...: Observer<T>): Observer<T>
	local Sources: {Observer<T>} = { ... }

	return Make(function(Emit: (T) -> ())
		local Connections: {Connection} = {}
		for _, Source in Sources do
			table.insert(Connections, Source:Subscribe(Emit))
		end

		return Deconstructor(table.unpack(Connections))
	end)
end

table.freeze(Observer)
return table.freeze({
	New = NewSubject,
	Value = NewValue,
	From = FromSignal,
	Merge = Merge,
	Source = Make,
})
