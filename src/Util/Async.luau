--!strict
--!optimize 2

--[=[
	Async: The scheduling Ledger hands to the engine, in one place a test can replace.

	Defer runs something after the step that asked for it, and Delay runs something later. Both go to
	the task library by default, which means the engine decides when they land. A harness that drives
	its own scheduler replaces them, and every thread Ledger starts then belongs to that harness, so a
	seeded run gives the same order every time.
	A spawn is not here. It resumes on the spot, so it already runs in the order the caller set.
	Cancel goes with them, because a handle from a replaced Delay is not the engine's to cancel.

	Return type: A table with Set, Defer, Delay and Cancel.
	Example usage:
		local Async = require("./Async")
		Async.Set(Defer, Delay, Cancel)
--]=]

export type Defers = (Callback: (...any) -> (), ...any) -> thread
export type Delays = (Seconds: number, Callback: (...any) -> (), ...any) -> thread
export type Cancels = (Held: thread) -> ()

local function Later(Callback: (...any) -> (), ...: any): thread
	return task.defer(Callback, ...)
end

local function After(Seconds: number, Callback: (...any) -> (), ...: any): thread
	return task.delay(Seconds, Callback, ...)
end

local function Drop(Held: thread)
	if coroutine.status(Held) ~= "suspended" then
		return
	end
	task.cancel(Held)
end

local Deferring: Defers = Later
local Delaying: Delays = After
local Cancelling: Cancels = Drop

local function Set(Defer: Defers?, Delay: Delays?, Cancel: Cancels?)
	assert(Defer == nil or type(Defer) == "function", "the defer given to Ledger.UseAsync has to be a function that takes a callback")
	assert(Delay == nil or type(Delay) == "function", "the delay given to Ledger.UseAsync has to be a function that takes seconds and a callback")
	assert(Cancel == nil or type(Cancel) == "function", "the cancel given to Ledger.UseAsync has to be a function that takes a thread")

	Deferring = Defer or Later
	Delaying = Delay or After
	Cancelling = Cancel or Drop
end

local function Defer(Callback: (...any) -> (), ...: any): thread
	return Deferring(Callback, ...)
end

local function Delay(Seconds: number, Callback: (...any) -> (), ...: any): thread
	return Delaying(Seconds, Callback, ...)
end

local function Cancel(Held: thread)
	Cancelling(Held)
end

return table.freeze({
	Set = Set,
	Defer = Defer,
	Delay = Delay,
	Cancel = Cancel,
})
