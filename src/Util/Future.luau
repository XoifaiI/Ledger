--!strict
--!optimize 2

-- eager async result, runs your callback on its own thread and you grab the result with :Wait()

local Threads = require("./Threads")

local Future = {}
Future.__index = Future

type Packed = { n: number, [number]: any }

type FutureImpl<T...> = {
	__index: FutureImpl<T...>,

	Wait: (self: Future<T...>, Timeout: number?) -> T...,
	Happened: (self: Future<T...>, Wait: boolean?) -> boolean
}

export type Future<T...> = setmetatable<{}, FutureImpl<T...>>

type Private<T...> = {
	Result: Packed?,
	Waiting: { thread },
	Timeouts: { thread },
	Thread: thread?
}

local function ToPrivate<T...>(self: Future<T...>): Private<T...>
	return self :: any
end

local function IsHappening<T...>(self: Future<T...>): boolean
	local Thread = ToPrivate(self).Thread
	return Thread ~= nil and coroutine.status(Thread) == "suspended"
end

local function TryRemove(List: { any }, Value: any): boolean
	local Position = table.find(List, Value)
	return Position ~= nil and table.remove(List, Position) ~= nil
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

local function TimeoutTask<T...>(Inst: Future<T...>, Caller: thread)
	if not IsHappening(Inst) or coroutine.status(Caller) ~= "suspended" then
		return
	end

	local Private = ToPrivate(Inst)
	if not TryRemove(Private.Waiting, Caller) then
		return
	end

	TryRemove(Private.Timeouts, coroutine.running())
	Threads.Resume(Caller)
end

local function FutureTask<Args..., Ret...>(Callback: (Args...) -> Ret..., Inst: Future<Ret...>, ...: Args...)
	local Private = ToPrivate(Inst)

	Private.Result = Pack(pcall(Callback, ...))

	Finish(Private, Unpack(Private))
end

local function New<Args..., Ret...>(Callback: (Args...) -> Ret..., ...: Args...): Future<Ret...>
	local Body: Private<Ret...> = {
		Waiting = {},
		Timeouts = {}
	}

	local NewFuture: Future<Ret...> = setmetatable(Body :: any, Future)

	Body.Thread = task.spawn(FutureTask, Callback, NewFuture, ...)

	return NewFuture
end

function Future.Wait<T...>(self: Future<T...>, Timeout: number?): T...
	local Private = ToPrivate(self)

	if not IsHappening(self) then
		return Unpack(Private)
	end

	local Caller = coroutine.running()
	table.insert(Private.Waiting, Caller)

	if Timeout then
		table.insert(Private.Timeouts, task.delay(Timeout, TimeoutTask, self, Caller))
	end

	return coroutine.yield()
end

function Future.Happened<T...>(self: Future<T...>, Wait: boolean?): boolean
	if IsHappening(self) then
		if not Wait then
			return false
		end
		self:Wait()
	end

	local Result = ToPrivate(self).Result
	if Result and type(Result[1]) == "boolean" then
		return Result[1]
	end

	return false
end

local function Settled<T...>(Result: Packed): Future<T...>
	local Body: Private<T...> = {
		Result = Result,
		Waiting = {},
		Timeouts = {}
	}

	return setmetatable(Body :: any, Future)
end

local function NewCompleted<T...>(...: T...): Future<T...>
	return Settled(Pack(true, ...))
end

local function NewErrored<T...>(Reason: string): Future<T...>
	return Settled(Pack(false, Reason))
end

table.freeze(Future)
return table.freeze({
	New = New,

	Completed = NewCompleted,
	Errored = NewErrored
})
