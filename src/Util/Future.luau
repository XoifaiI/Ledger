--!strict
--!optimize 2

--[=[
    Future: eager async result, runs your callback on its own thread and you grab the result with :Wait()

    Return type: frozen table { New, Is, Completed, Cancelled, Errored }
    Example usage:
        local Future = require("./Future")
        local Job = Future.New(function()
            return 42
        end)
        local Result = Job:Wait()
--]=]

local Threads = require("./Threads")

local Future = {}
Future.__index = Future

type Packed = { n: number, [number]: any }

type FutureImpl<T...> = {
	__index: FutureImpl<T...>,

	Wait: (self: Future<T...>, Timeout: number?) -> T...,
	Cancel: (self: Future<T...>) -> (),

	Data: (self: Future<T...>) -> T...,
	Happened: (self: Future<T...>, Wait: boolean?) -> boolean,
	Cancelled: (self: Future<T...>) -> (boolean, any),
}

export type Future<T...> = setmetatable<{}, FutureImpl<T...>>

type Private<T...> = {
	__future: boolean,

	Result: Packed?,
	WasCancelled: boolean,

	Waiting: {thread},
	Timeouts: {thread},

	Thread: thread?,
}

local function ToPrivate<T...>(self: Future<T...>): Private<T...>
	return self :: any
end

local function TryRemove(List: {any}, Value: any): boolean
	local Position = table.find(List, Value)
	return Position ~= nil and table.remove(List, Position) ~= nil
end

local function IsFuture(Value: any): boolean
	return type(Value) == "table" and rawget(Value, "__future") == true
end

local function FutureIsHappening<T...>(self: Future<T...>): boolean
	local Private = ToPrivate(self)
	local Thread = Private.Thread

	return not Private.WasCancelled
		and Thread ~= nil
		and coroutine.status(Thread) == "suspended"
end

local EMPTY: Packed = table.freeze({ n = 0 }) :: any

local function Pack(...: any): Packed
	return table.pack(...)
end

local function Unpack<T...>(self: Private<T...>): T...
	local Result = self.Result

	if Result and Result[1] == true then
		return table.unpack(Result, 2, Result.n)
	end

	return table.unpack(EMPTY, 1, 0)
end

local function Finish<T...>(self: Private<T...>, ...: any)
	for _, TimeoutThread in self.Timeouts do
		if coroutine.status(TimeoutThread) ~= "suspended" then
			continue
		end

		task.cancel(TimeoutThread)
	end

	for _, WaitingThread in self.Waiting do
		Threads.Resume(WaitingThread, ...)
	end

	table.clear(self.Waiting)
	table.clear(self.Timeouts)
end

local function TryFlatten<T...>(self: Private<T...>)
	local Result = self.Result
	if not (Result and Result[1] == true) then
		return
	end

	local Inner = Result[2]
	if not IsFuture(Inner) then
		return
	end

	if getmetatable(Inner) == Future and FutureIsHappening(Inner) then
		Inner:Wait()
	end

	local InnerPrivate = ToPrivate(Inner)
	self.Result = InnerPrivate.Result
	self.WasCancelled = InnerPrivate.WasCancelled
end

local function FutureTask<Args..., Ret...>(Callback: (Args...) -> Ret..., Inst: Future<Ret...>, ...: Args...)
	local Private = ToPrivate(Inst)

	Private.Result = Pack(pcall(Callback, ...))
	TryFlatten(Private)

	Finish(Private, Unpack(Private))
end

local function TimeoutTask<T...>(Inst: Future<T...>, Caller: thread)
	local Self = coroutine.running()

	if not FutureIsHappening(Inst) then
		return
	end

	if coroutine.status(Caller) ~= "suspended" then
		return
	end

	local Private = ToPrivate(Inst)
	if not TryRemove(Private.Waiting, Caller) then
		return
	end

	TryRemove(Private.Timeouts, Self)

	Threads.Resume(Caller)
end

local function New<Args..., Ret...>(Callback: (Args...) -> Ret..., ...: Args...): Future<Ret...>
	local Body: Private<Ret...> = {
		__future = true,
		WasCancelled = false,
		Waiting = {},
		Timeouts = {},
	}

	local NewFuture: Future<Ret...> = setmetatable(Body :: any, Future)

	Body.Thread = task.spawn(FutureTask, Callback, NewFuture, ...)

	return NewFuture
end

function Future.Wait<T...>(self: Future<T...>, Timeout: number?): T...
	local Private = ToPrivate(self)

	if not FutureIsHappening(self) then
		return Unpack(Private)
	end

	local Caller = coroutine.running()
	table.insert(Private.Waiting, Caller)

	if Timeout then
		table.insert(Private.Timeouts, task.delay(Timeout, TimeoutTask, self, Caller))
	end

	return coroutine.yield()
end

function Future.Cancel<T...>(self: Future<T...>)
	if not FutureIsHappening(self) then
		return
	end

	local Private = ToPrivate(self)
	Private.WasCancelled = true

	Finish(Private)

	local Thread = Private.Thread
	if Thread and coroutine.status(Thread) == "suspended" then
		task.cancel(Thread)
	end
end

function Future.Happened<T...>(self: Future<T...>, Wait: boolean?): boolean
	if FutureIsHappening(self) then
		if not Wait then
			return false
		end
		self:Wait()
	end

	local Private = ToPrivate(self)
	if Private.WasCancelled then
		return false
	end

	local Result = Private.Result
	if Result and type(Result[1]) == "boolean" then
		return Result[1]
	end

	return false
end

function Future.Cancelled<T...>(self: Future<T...>): (boolean, any)
	local Private = ToPrivate(self)

	local Result = Private.Result
	if Result and Result[1] == false then
		return true, Result[2]
	end

	if Private.WasCancelled then
		return true
	end

	return false
end

function Future.Data<T...>(self: Future<T...>): T...
	return Unpack(ToPrivate(self))
end

local function Settled<T...>(Result: Packed?, WasCancelled: boolean): Future<T...>
	local Body: Private<T...> = {
		__future = true,
		Result = Result,
		WasCancelled = WasCancelled,
		Waiting = {},
		Timeouts = {},
	}

	return setmetatable(Body :: any, Future)
end

local function NewCompleted<T...>(...: T...): Future<T...>
	return Settled(Pack(true, ...), false)
end

local function NewCancelled<T...>(): Future<T...>
	return Settled(nil, true)
end

local function NewErrored<T...>(Reason: string): Future<T...>
	return Settled(Pack(false, Reason), false)
end

table.freeze(Future)
return table.freeze({
	New = New,
	Is = IsFuture,

	Completed = NewCompleted,
	Cancelled = NewCancelled,
	Errored = NewErrored,
})
