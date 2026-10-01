--!strict
--!optimize 2

--[=[

	Asks: Logic. What a machine may ask for, and what it hears back.

	Send runs one request through Step on a key. Read reads a key. Remove removes a key, once. Wait
	passes time. Run runs another machine. Count adds 1 to one of the counter keys that hand out
	server numbers. Item reads an item of a MemoryStore hash map, Change runs a transform on one, Put
	sets one and Drop removes one, each once. The runner answers
	each ask once with a heard reply, and so do the tests. A reply to a Send carries its word: the
	note's report, else its why, else Done. It also carries the note, whether any run of it returned a
	write, and every op number any run decided. A reply to a Read carries the value, and one to a
	Count the count its own write made. A reply to an Item carries its value, and one to a Change
	the value it wrote, or nil when the transform cancelled. Put and Drop hear Done. A reply to a Run carries the answer. A reply that failed says
	Failed. Every reply carries the time it came back.

	Return type: A table with Send, Read, Remove, Wait, Run, Count, Item, Change, Put, Drop, Noted,
	Got, Done, Failed and SAID. The
	types are Place, Ask and Heard.
	Example usage:
		Machine.Ask(Call, Asks.Send(Ref, Request))
--]=]

local Book = require("../Record/Book")
local DataStore = require("../Adapters/DataStore")
local Types = require("../Record/Types")

export type Place = {
	read Store: DataStore.Store,
	read Build: Types.Build,
}

export type Ask =
	{ read Kind: "Send", read Ref: Book.Ref, read Request: Types.Request, read UserIds: { number }? }
	| { read Kind: "Read", read Ref: Book.Ref }
	| { read Kind: "Remove", read Ref: Book.Ref }
	| { read Kind: "Wait", read Seconds: number }
	| { read Kind: "Run", read Machine: any, read Context: any }
	| { read Kind: "Count", read Index: number }
	| { read Kind: "Item", read Map: string, read Key: string }
	| { read Kind: "Change", read Map: string, read Key: string, read Transform: (Current: unknown) -> unknown, read Expiry: number }
	| { read Kind: "Put", read Map: string, read Key: string, read Value: unknown, read Expiry: number }
	| { read Kind: "Drop", read Map: string, read Key: string }

export type Heard = {
	read Said: string,
	read Now: number,
	read Note: Types.Note?,
	read Wrote: boolean,
	read Ran: { [number]: true },
	read Value: unknown,
	read Answer: unknown,
}

local SAID: {
	read Done: "Done",
	read Failed: "Failed",
} = {
	Done = "Done",
	Failed = "Failed",
}

local Asks = { SAID = SAID }

function Asks.Send(Ref: Book.Ref, Request: Types.Request, UserIds: { number }?): Ask
	return { Kind = "Send", Ref = Ref, Request = Request, UserIds = UserIds }
end

function Asks.Read(Ref: Book.Ref): Ask
	return { Kind = "Read", Ref = Ref }
end

function Asks.Remove(Ref: Book.Ref): Ask
	return { Kind = "Remove", Ref = Ref }
end

function Asks.Wait(Seconds: number): Ask
	return { Kind = "Wait", Seconds = math.max(Seconds, 0) }
end

function Asks.Run(Machine: any, Context: any): Ask
	return { Kind = "Run", Machine = Machine, Context = Context }
end

function Asks.Count(Index: number): Ask
	return { Kind = "Count", Index = Index }
end

function Asks.Item(Map: string, Key: string): Ask
	return { Kind = "Item", Map = Map, Key = Key }
end

function Asks.Change(Map: string, Key: string, Transform: (Current: unknown) -> unknown, Expiry: number): Ask
	return { Kind = "Change", Map = Map, Key = Key, Transform = Transform, Expiry = Expiry }
end

function Asks.Put(Map: string, Key: string, Value: unknown, Expiry: number): Ask
	return { Kind = "Put", Map = Map, Key = Key, Value = Value, Expiry = Expiry }
end

function Asks.Drop(Map: string, Key: string): Ask
	return { Kind = "Drop", Map = Map, Key = Key }
end

function Asks.Noted(Note: Types.Note, Now: number, Wrote: boolean?, Ran: { [number]: true }?): Heard
	return {
		Said = Note.Report or Note.Why or SAID.Done,
		Now = Now,
		Note = Note,
		Wrote = Wrote == true,
		Ran = Ran or {},
	}
end

function Asks.Got(Value: unknown, Now: number): Heard
	return { Said = SAID.Done, Now = Now, Wrote = false, Ran = {}, Value = Value }
end

function Asks.Done(Now: number, Answer: unknown?): Heard
	return { Said = SAID.Done, Now = Now, Wrote = false, Ran = {}, Answer = Answer }
end

function Asks.Failed(Now: number, Wrote: boolean): Heard
	return { Said = SAID.Failed, Now = Now, Wrote = Wrote, Ran = {} }
end

return Asks
