--!strict
--!optimize 2

--[=[

	Future: Holds the answer to a call that has not finished yet.

	Pending gives back a future and the function that settles it. Wait gives back the answer, and a
	thread that waits before it is settled sleeps until then. Wait takes a timeout, and a wait that
	times out gives back nothing. Happened says whether the future has settled, and waits for it when
	asked to. A future settles once. Pack is not table.pack under another name: it widens a generic
	type pack to any, which is the only way the checker packs one.

	Return type: A table with Pending and Completed.
	Example usage:
		local Future = require("./Future")
		local Job, Settle = Future.Pending()
		task.defer(Settle, true)
		local Answer = Job:Wait()
--]=]

type Packed = { n: number, [number]: any }

type FutureImpl<T...> = {
	__index: FutureImpl<T...>,

	Wait: (self: Future<T...>, Timeout: number?) -> T...,
	Happened: (self: Future<T...>, Wait: boolean?) -> boolean,
}

export type Future<T...> = setmetatable<{}, FutureImpl<T...>>

type Private = {
	Result: Packed?,
	Waiting: { [thread]: thread | false }?,
}

local Future = {} :: FutureImpl<...any>
Future.__index = Future

local function ToPrivate<T...>(self: Future<T...>): Private
	return self :: any
end

local function Pack(...: any): Packed
	return table.pack(...)
end

local function Settle(Body: Private, ...: any)
	assert(Body.Result == nil, "a future settled twice, so a thread waiting on it would read the wrong answer")
	Body.Result = Pack(...)
	local Waiting = Body.Waiting
	if Waiting == nil then
		return
	end
	Body.Waiting = nil
	for Caller, Timer in Waiting do
		if Timer then
			task.cancel(Timer)
		end
		task.spawn(Caller, ...)
	end
end

local function Expire(Body: Private, Caller: thread)
	local Waiting = Body.Waiting
	if Waiting == nil or Waiting[Caller] == nil then
		return
	end
	Waiting[Caller] = nil
	task.spawn(Caller)
end

local function Pending<T...>(): (Future<T...>, (T...) -> ())
	local Body: Private = {}
	local function Done(...: T...)
		Settle(Body, ...)
	end
	return setmetatable(Body :: any, Future), Done
end

local function Completed<T...>(...: T...): Future<T...>
	local Body: Private = { Result = Pack(...) }
	return setmetatable(Body :: any, Future)
end

function Future.Wait<T...>(self: Future<T...>, Timeout: number?): T...
	local Body = ToPrivate(self)
	local Result = Body.Result
	if Result then
		return table.unpack(Result, 1, Result.n)
	end
	local Caller = coroutine.running()
	local Waiting = Body.Waiting or {}
	Body.Waiting = Waiting
	Waiting[Caller] = if Timeout then task.delay(Timeout, Expire, Body, Caller) else false
	return coroutine.yield()
end

function Future.Happened<T...>(self: Future<T...>, Wait: boolean?): boolean
	if Wait and ToPrivate(self).Result == nil then
		self:Wait()
	end
	return ToPrivate(self).Result ~= nil
end

table.freeze(Future)

return table.freeze({
	Pending = Pending,
	Completed = Completed,
})
