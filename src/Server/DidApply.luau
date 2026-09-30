--!strict
--!optimize 2

--[=[

	DidApply: The machines that say whether a game's name took effect on a key.

	Reading reads the key once: true if it holds the name as took, else Unresolved. It is the only
	form for an untimed name, which never answers false. Probing sends a probe that decides nothing:
	a held name answers true if it took and false if not, a forgotten one Unresolved, and a probe that
	lands answers false for the moment it landed. A call that fails waits as Backoff says and is sent
	again, and after Limits.TRIES failures the call answers Unresolved.

	Return type: A table with Reading, Probing and Context.
	Example usage:
		local Applied = Driver.Run(DidApply.Probing, DidApply.Context(Store, Name, Build, Probe)):Wait()
--]=]

local Answer = require("../Core/Answer")
local Backoff = require("./Backoff")
local Book = require("../Record/Book")
local Clock = require("./Clock")
local DataStore = require("../Adapters/DataStore")
local Effect = require("./Effect")
local Key = require("../Record/Key")
local Limits = require("../Core/Constants/Limits")
local Machine = require("../Core/Machine")
local Step = require("../Record/Step")
local Types = require("../Record/Types")

type Answer = Answer.Answer
type Result = boolean | Answer

export type Context = {
	read Store: DataStore.Store,
	read Name: string,
	read Build: Types.Build,
	read Probe: Types.Probe,
	Tries: number,
	Note: Types.Note?,
}

type Call = Effect.Call<Context, Result>

local STATE: {
	read Reading: "Reading",
	read Probing: "Probing",
	read RestingRead: "RestingRead",
	read RestingProbe: "RestingProbe",
	read Done: "Done",
} = {
	Reading = "Reading",
	Probing = "Probing",
	RestingRead = "RestingRead",
	RestingProbe = "RestingProbe",
	Done = "Done",
}

local STOPS: { [Types.Why]: Answer } = {
	[Types.Why.Missing] = Answer.Missing,
	[Types.Why.Behind] = Answer.Behind,
	[Types.Why.Worn] = Answer.Worn,
}

local DidApply = {}

local function Settle(Call: Call, Result: Result): string
	Machine.Answer(Call, Result)
	return STATE.Done
end

local function Failed(Call: Call, Rest: string): string
	Call.Context.Tries += 1
	return if Call.Context.Tries >= Limits.TRIES then Settle(Call, Answer.Unresolved) else Rest
end

local function Read(Call: Call)
	Machine.Send(Call, Effect.Get(Call.Context.Store, Call.Context.Name))
end

local function Got(Call: Call, Ok: boolean, Value: unknown): string?
	if not Ok then
		return Failed(Call, STATE.RestingRead)
	end
	local Found = Key.Read(Value)
	local Item = if type(Found) == "table" then Found.Book:Held(Call.Context.Probe.Name) else nil
	return Settle(Call, if Item and Item.Fate == Book.Fate.Took then true else Answer.Unresolved)
end

local function Probe(Call: Call)
	local Context = Call.Context
	Context.Note = nil
	local Request: Types.Request = { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Probe = Context.Probe }
	local function Transform(Current: unknown, _: DataStoreKeyInfo?): unknown
		local Note = Step(Current, Request, Clock.Now(), Context.Build)
		Context.Note = Note
		return Note.Stored
	end
	Machine.Send(Call, Effect.Update(Context.Store, Context.Name, Transform))
end

local function Probed(Call: Call, Ok: boolean): string?
	local Note = Call.Context.Note
	if not Ok or Note == nil then
		return Failed(Call, STATE.RestingProbe)
	elseif Note.Held then
		return Settle(Call, Note.Held == Book.Fate.Took)
	elseif Note.Stored then
		return Settle(Call, false)
	end
	return Settle(Call, STOPS[Note.Why :: Types.Why] or Answer.Unresolved)
end

local function Rest(Call: Call)
	Machine.Send(Call, Effect.Wait(Backoff(Call.Context.Tries)))
end

local function ToRead(): string?
	return STATE.Reading
end

local function ToProbe(): string?
	return STATE.Probing
end

local STATES: { [string]: Effect.State<Context, Result> } = {
	[STATE.Reading] = { To = { STATE.RestingRead, STATE.Done }, Enter = Read, On = Got },
	[STATE.Probing] = { To = { STATE.RestingProbe, STATE.Done }, Enter = Probe, On = Probed },
	[STATE.RestingRead] = { To = { STATE.Reading }, Enter = Rest, On = ToRead },
	[STATE.RestingProbe] = { To = { STATE.Probing }, Enter = Rest, On = ToProbe },
	[STATE.Done] = {},
}

local READING: Effect.Spec<Context, Result> = { Name = "DidApply", Initial = STATE.Reading, States = STATES }
local PROBING: Effect.Spec<Context, Result> = { Name = "DidApply", Initial = STATE.Probing, States = STATES }

function DidApply.Context(Store: DataStore.Store, Name: string, Build: Types.Build, Asked: Types.Probe): Context
	return { Store = Store, Name = Name, Build = Build, Probe = Asked, Tries = 0 }
end

DidApply.Reading = Machine.Define(READING)
DidApply.Probing = Machine.Define(PROBING)

return DidApply
