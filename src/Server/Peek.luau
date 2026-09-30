--!strict
--!optimize 2

--[=[

	Peek: The machines that show a key's state, never older than this server showed before.

	Cached starts with a read, and Fresh with a fresh read, an update that decides nothing and lands.
	A read the shown table does not allow goes on to a fresh read, which is always current. A call
	that fails waits as Backoff says and is sent again, and after Limits.TRIES failures the peek
	answers Unresolved.

	Return type: A table with Cached, Fresh and Context.
	Example usage:
		local Shown = Driver.Run(Peek.Cached, Peek.Context(Store, Name, Mark, Build, Table)):Wait()
--]=]

local Answer = require("../Core/Answer")
local Backoff = require("./Backoff")
local Clock = require("./Clock")
local DataStore = require("../Adapters/DataStore")
local Effect = require("./Effect")
local Limits = require("../Core/Constants/Limits")
local Machine = require("../Core/Machine")
local Shown = require("./Shown")
local Step = require("../Record/Step")
local Types = require("../Record/Types")
local View = require("../Record/View")

type Answer = Answer.Answer

export type Context = {
	read Store: DataStore.Store,
	read Name: string,
	read Mark: string,
	read Build: Types.Build,
	read Shown: Shown.Shown,
	Tries: number,
	Note: Types.Note?,
}

type Call = Effect.Call<Context, View.View | Answer>

local STATE: {
	read Reading: "Reading",
	read Refreshing: "Refreshing",
	read RestingRead: "RestingRead",
	read RestingFresh: "RestingFresh",
	read Done: "Done",
} = {
	Reading = "Reading",
	Refreshing = "Refreshing",
	RestingRead = "RestingRead",
	RestingFresh = "RestingFresh",
	Done = "Done",
}

local FRESH: Types.Request = { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Fresh = true }

local STOPS: { [Types.Why]: Answer } = {
	[Types.Why.Missing] = Answer.Missing,
	[Types.Why.Behind] = Answer.Behind,
	[Types.Why.Worn] = Answer.Worn,
}

local Peek = {}

local function Settle(Call: Call, Result: View.View | Answer): string
	Machine.Answer(Call, Result)
	return STATE.Done
end

local function Show(Call: Call, Found: View.View | Answer): string
	local Context = Call.Context
	if type(Found) == "string" then
		return Settle(Call, Found)
	end
	Context.Shown:Show(Context.Mark, Found.Writes)
	return Settle(Call, Found)
end

local function Failed(Call: Call, Rest: string): string
	Call.Context.Tries += 1
	return if Call.Context.Tries >= Limits.TRIES then Settle(Call, Answer.Unresolved) else Rest
end

local function Read(Call: Call)
	Machine.Send(Call, Effect.Get(Call.Context.Store, Call.Context.Name))
end

local function Got(Call: Call, Ok: boolean, Value: unknown): string?
	local Context = Call.Context
	if not Ok then
		return Failed(Call, STATE.RestingRead)
	end
	local Found = View.Read(Value, Context.Build)
	local Writes = if type(Found) == "string" then 0 else Found.Writes
	if not Context.Shown:Allows(Context.Mark, Writes) then
		return STATE.Refreshing
	end
	return Show(Call, Found)
end

local function Refresh(Call: Call)
	local Context = Call.Context
	Context.Note = nil
	local function Transform(Current: unknown, _: DataStoreKeyInfo?): unknown
		local Note = Step(Current, FRESH, Clock.Now(), Context.Build)
		Context.Note = Note
		return Note.Stored
	end
	Machine.Send(Call, Effect.Update(Context.Store, Context.Name, Transform))
end

local function Refreshed(Call: Call, Ok: boolean): string?
	local Note = Call.Context.Note
	if not Ok or Note == nil then
		return Failed(Call, STATE.RestingFresh)
	elseif Note.Stored then
		return Show(Call, View.Read(Note.Stored, Call.Context.Build))
	end
	return Settle(Call, STOPS[Note.Why :: Types.Why] or Answer.Unresolved)
end

local function Rest(Call: Call)
	Machine.Send(Call, Effect.Wait(Backoff(Call.Context.Tries)))
end

local function ToRead(): string?
	return STATE.Reading
end

local function ToRefresh(): string?
	return STATE.Refreshing
end

local STATES: { [string]: Effect.State<Context, View.View | Answer> } = {
	[STATE.Reading] = { To = { STATE.Refreshing, STATE.RestingRead, STATE.Done }, Enter = Read, On = Got },
	[STATE.Refreshing] = { To = { STATE.RestingFresh, STATE.Done }, Enter = Refresh, On = Refreshed },
	[STATE.RestingRead] = { To = { STATE.Reading }, Enter = Rest, On = ToRead },
	[STATE.RestingFresh] = { To = { STATE.Refreshing }, Enter = Rest, On = ToRefresh },
	[STATE.Done] = {},
}

function Peek.Context(Store: DataStore.Store, Name: string, Mark: string, Build: Types.Build, Table: Shown.Shown): Context
	return { Store = Store, Name = Name, Mark = Mark, Build = Build, Shown = Table, Tries = 0 }
end

local CACHED: Effect.Spec<Context, View.View | Answer> = { Name = "Peek", Initial = STATE.Reading, States = STATES }
local FRESHENED: Effect.Spec<Context, View.View | Answer> = { Name = "Peek", Initial = STATE.Refreshing, States = STATES }

Peek.Cached = Machine.Define(CACHED)
Peek.Fresh = Machine.Define(FRESHENED)

return Peek
