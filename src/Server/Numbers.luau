--!strict
--!optimize 2

--[=[

	Numbers: The machine that takes this server's number from the counter key its JobId hashes to.

	The number is the count its own write made, times Limits.COUNTERS, plus the index of the key. A
	try that does not land waits as Backoff says and is sent again.

	Return type: A table with Take, Context, Key and Bump.
	Example usage:
		local Number = Driver.Run(Numbers.Take, Numbers.Context(Store, game.JobId)):Wait()
--]=]

local Backoff = require("./Backoff")
local DataStore = require("../Adapters/DataStore")
local Effect = require("./Effect")
local Hash = require("../Encode/Hash")
local Limits = require("../Core/Constants/Limits")
local Machine = require("../Core/Machine")

export type Context = {
	read Store: DataStore.Store,
	read Index: number,
	Tries: number,
}

type Call = Effect.Call<Context, number>
type Spec = Effect.Spec<Context, number>

local STATE: {
	read Taking: "Taking",
	read Resting: "Resting",
	read Done: "Done",
} = {
	Taking = "Taking",
	Resting = "Resting",
	Done = "Done",
}

local Numbers = {}

function Numbers.Key(Index: number): string
	return `n{Index}`
end

function Numbers.Bump(Current: unknown): unknown
	if Current == nil then
		return 1
	elseif type(Current) == "number" and Current % 1 == 0 and Current >= 0 then
		return Current + 1
	end
	return nil
end

function Numbers.Context(Store: DataStore.Store, JobId: string): Context
	return { Store = Store, Index = Hash(JobId) % Limits.COUNTERS, Tries = 0 }
end

local function Send(Call: Call)
	Machine.Send(Call, Effect.Update(Call.Context.Store, Numbers.Key(Call.Context.Index), Numbers.Bump))
end

local function Taken(Call: Call, Ok: boolean, Count: unknown, _: DataStoreKeyInfo?, Wrote: boolean?): string?
	if Ok and Wrote and type(Count) == "number" then
		Machine.Answer(Call, Count * Limits.COUNTERS + Call.Context.Index)
		return STATE.Done
	end
	Call.Context.Tries += 1
	return STATE.Resting
end

local function Rest(Call: Call)
	Machine.Send(Call, Effect.Wait(Backoff(Call.Context.Tries)))
end

local function Rested(): string?
	return STATE.Taking
end

local SPEC: Spec = {
	Name = "Numbers",
	Initial = STATE.Taking,
	States = {
		[STATE.Taking] = { To = { STATE.Resting, STATE.Done }, Enter = Send, On = Taken },
		[STATE.Resting] = { To = { STATE.Taking }, Enter = Rest, On = Rested },
		[STATE.Done] = {},
	},
}

Numbers.Take = Machine.Define(SPEC)

return Numbers
