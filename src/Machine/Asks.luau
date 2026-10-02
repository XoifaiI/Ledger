--!strict
--!optimize 2

--[=[
	Asks: Logic. What a machine may ask for, and what it hears back.

	Every ask is answered once, by the runner or a test, with the time the reply came back, so a
	machine never reads a clock. A Send's word is the note's report, else its why, else Done. Its
	reply also says whether any run returned a write and which op numbers any run decided. A Change
	hears the value it wrote, or nil when its transform cancelled. A failed write may have written,
	and its reply says so. Run carries its machine as any, since Machine requires this module.

	Return type: A table of the ask and reply builders and SAID, and the Place, Ask and Heard types.
	Example usage:
		Machine.Ask(Call, Asks.Send(Ref, Request))
--]=]

local Book = require("../Record/Book")
local DataStore = require("../Adapters/DataStore")
local Requests = require("../Record/Requests")
local Types = require("../Record/Types")

export type Place = {
	read Store: DataStore.Store,
	read Build: Types.Build,
}

export type Ask =
	{ read Kind: "Send", read Ref: Book.Ref, read Request: Requests.Request, read UserIds: { number }? }
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

local SAID = {
	Done = "Done" :: "Done",
	Failed = "Failed" :: "Failed",
}

local Asks = { SAID = SAID }

function Asks.Send(Ref: Book.Ref, Request: Requests.Request, UserIds: { number }?): Ask
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
