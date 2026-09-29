--!strict
--!optimize 2

--[=[

	Numbers: Takes a server number from one of Limits.COUNTERS counter keys.

	A server picks its counter key by a hash of its JobId, and adds 1 to it in one update. Its number
	is the count its own write made, times COUNTERS, plus the index of the key, so no two servers ever
	hold the same number. A call that fails, or finds the key holding something other than a count,
	waits and is sent again. The wait starts at 1 second and doubles up to Windows.BACKOFF. A lost
	answer wastes a number and nothing else.

	Return type: A table with Take, Context, Key and Bump.
	Example usage:
		local Numbers = require("./Numbers")
		local Number = Driver.Run(Numbers.Take, Numbers.Context(Store, game.JobId)):Wait()
--]=]

local DataStore = require("../Adapters/DataStore")
local Effect = require("./Effect")
local Hash = require("../Encode/Hash")
local Limits = require("../Core/Constants/Limits")
local Machine = require("../Core/Machine")
local Windows = require("../Core/Constants/Windows")

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

local function Key(Index: number): string
	return `n{Index}`
end

local function Bump(Current: unknown): unknown
	if Current == nil then
		return 1
	elseif type(Current) == "number" and Current % 1 == 0 and Current >= 0 then
		return Current + 1
	end
	return nil
end

local function Context(Store: DataStore.Store, JobId: string): Context
	return { Store = Store, Index = Hash(JobId) % Limits.COUNTERS, Tries = 0 }
end

local function Send(Call: Call)
	Machine.Send(Call, Effect.Update(Call.Context.Store, Key(Call.Context.Index), Bump))
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
	Machine.Send(Call, Effect.Wait(math.min(2 ^ (Call.Context.Tries - 1), Windows.BACKOFF)))
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

return table.freeze({
	Take = Machine.Define(SPEC),
	Context = Context,
	Key = Key,
	Bump = Bump,
})
