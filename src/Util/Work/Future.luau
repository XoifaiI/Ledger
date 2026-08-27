--!strict
--!optimize 2

--[=[
	Future: Holds the result of work that runs on its own thread.

	The work starts immediately. Wait gives you the result.
	If the work fails, Wait gives you nothing, and Happened tells you that it failed.

	Return type: A table with New, Completed and Errored.
	Example usage:
		local Future = require("./Future")
		local Job = Future.New(function() return 1 end)
		local Value = Job:Wait()
--]=]

local Async = require("../Engine/Async")
local Say = require("../Tools/Say")

local Threads = require("./Threads")

type Packed = { n: number, [number]: any }

type FutureImpl<T...> = {
	__index: FutureImpl<T...>,

	Wait: (self: Future<T...>, Timeout: number?) -> T...,
	Happened: (self: Future<T...>, Wait: boolean?) -> boolean,
}

export type Future<T...> = setmetatable<{}, FutureImpl<T...>>

type Private<T...> = {
	Result: Packed?,
	Waiting: { thread }?,
	Timeouts: { thread }?,
}

local EMPTY: Packed = table.freeze({ n = 0 }) :: any

local Future = {} :: FutureImpl<...any>
Future.__index = Future

local function ToPrivate<T...>(self: Future<T...>): Private<T...>
	return self :: any
end

local function IsHappening<T...>(self: Future<T...>): boolean
	return ToPrivate(self).Result == nil
end

local function TryRemove(List: { any }?, Value: any): boolean
	if List == nil then
		return false
	end

	local Position = table.find(List, Value)
	return Position ~= nil and table.remove(List, Position) ~= nil
end

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
	local Timeouts = self.Timeouts
	if Timeouts ~= nil then
		for _, TimeoutThread in Timeouts do
			if coroutine.status(TimeoutThread) ~= "suspended" then
				continue
			end

			task.cancel(TimeoutThread)
		end
		table.clear(Timeouts)
	end

	local Waiting = self.Waiting
	if Waiting ~= nil then
		for _, WaitingThread in Waiting do
			Threads.Resume(WaitingThread, ...)
		end
		table.clear(Waiting)
	end

	assert(self.Result ~= nil, "a future woke its waiters without an answer for them")
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
	assert(Private.Result == nil, "a future settled twice, so a waiting thread would be resumed with the wrong answer")

	local Result = Pack(pcall(Callback, ...))
	Private.Result = Result

	if not Result[1] then
		Say.Warn(`Ledger: Future callback errored: {tostring(Result[2])}`)
	end

	Finish(Private, Unpack(Private))
end

local Idle: { thread } = {}

local function Runner(...)
	FutureTask(...)

	while true do
		table.insert(Idle, coroutine.running())
		FutureTask(coroutine.yield())
	end
end

local function Start<Args..., Ret...>(Callback: (Args...) -> Ret..., Inst: Future<Ret...>, ...: Args...)
	local Count = #Idle
	if Count == 0 then
		task.spawn(coroutine.create(Runner) :: any, Callback, Inst, ...)
		return
	end

	local Thread = Idle[Count]
	Idle[Count] = nil
	task.spawn(Thread, Callback, Inst, ...)
end

local function Settled<T...>(Result: Packed): Future<T...>
	local Body: Private<T...> = { Result = Result }
	return setmetatable(Body :: any, Future)
end

local function New<Args..., Ret...>(Callback: (Args...) -> Ret..., ...: Args...): Future<Ret...>
	local Body: Private<Ret...> = {}
	local NewFuture: Future<Ret...> = setmetatable(Body :: any, Future)

	Start(Callback, NewFuture, ...)

	return NewFuture
end

local function NewCompleted<T...>(...: T...): Future<T...>
	return Settled(Pack(true, ...))
end

local function NewErrored<T...>(Reason: string): Future<T...>
	return Settled(Pack(false, Reason))
end

function Future.Wait<T...>(self: Future<T...>, Timeout: number?): T...
	local Private = ToPrivate(self)

	if not IsHappening(self) then
		return Unpack(Private)
	end

	local Caller = coroutine.running()
	local Waiting = Private.Waiting
	if Waiting == nil then
		Waiting = {}
		Private.Waiting = Waiting
	end
	table.insert(Waiting :: { thread }, Caller)

	if Timeout then
		local Timeouts = Private.Timeouts
		if Timeouts == nil then
			Timeouts = {}
			Private.Timeouts = Timeouts
		end
		table.insert(Timeouts :: { thread }, Async.Delay(Timeout, TimeoutTask, self, Caller))
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

table.freeze(Future)

return table.freeze({
	New = New,

	Completed = NewCompleted,
	Errored = NewErrored,
})
