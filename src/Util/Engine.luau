--!strict
--!optimize 2

--[=[

	Engine: The two things Ledger is handed rather than reaches for.

	A scheduler is everything to do with when code runs, and a hook is everything to do with where
	data goes. A store takes one of each when it is built. Neither carries self: an implementation
	binds its own state and hands back plain functions, and every field is read only.

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
