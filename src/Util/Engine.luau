--!strict
--!optimize 2

--[=[
	Engine: The two things Ledger is handed rather than reaches for.

	A scheduler is everything to do with when code runs, and a hook is everything to do with where
	data goes. Ledger takes one of each when a store is built and never looks for them anywhere else,
	so a run outside Roblox is a matter of handing over different ones rather than swapping a global
	out from under whatever is already live.
	Neither carries self. An implementation binds its own state at construction and hands back plain
	functions, because a method whose self is the concrete type cannot stand in for one whose self is
	the interface, and the checker is right to refuse it. Every field is read only, both because an
	implementation is frozen and because nothing should be reaching in to replace one of them.
	Resume runs a thread on the spot and Defer queues it. They are separate because code that waits
	on a queue deadlocks when the wake it is waiting for is put in the queue behind it.

	Return type: A table of the type names, for requiring the types alone.
	Example usage:
		local Engine = require("./Engine")
		local function Take(Held: Engine.Scheduler) end
--]=]

export type Scheduler = {
	read Now: () -> number,
	read Wait: (Seconds: number) -> (),
	read Spawn: (Body: (...any) -> (), ...any) -> thread,
	read Resume: (Thread: thread, ...any) -> boolean,
	read Defer: (Body: (...any) -> (), ...any) -> thread,
	read Delay: (Seconds: number, Body: (...any) -> (), ...any) -> thread,
	read Cancel: (Thread: thread) -> (),
}

export type Store = {
	read GetAsync: (self: any, Key: string) -> (any, any),
	read UpdateAsync: (self: any, Key: string, Transform: (any, any) -> any) -> (any, any),
	read RemoveAsync: (self: any, Key: string) -> (any, any),
	read GetVersionAsync: (self: any, Key: string, Version: string) -> (any, any),
	read ListVersionsAsync: (self: any, Key: string, Direction: Enum.SortDirection?, Least: number?, Most: number?, Size: number?) -> any,
	read ListKeysAsync: (self: any, Prefix: string?, Size: number?, Cursor: string?, Hiding: boolean?) -> any,
}

export type Hook = {
	read Open: (Name: string) -> Store,
	read Budget: (Kind: Enum.DataStoreRequestType) -> number,
}

return table.freeze({})
