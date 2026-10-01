--!strict
--!optimize 2

--[=[

	Number: Machine. Takes a server number from the counter key the server's JobId hashes to.

	Spec: record 3.1.

	The number is the count its own write made, times Limits.COUNTERS, plus the index of the key. A
	count that fails rests as Backoff says and is asked again, until one lands.

	Return type: A table with Machine and Context. The type is Context.
	Example usage:
		local Number = Runner.Run(Number.Machine, Number.Context(game.JobId), Places):Wait()
--]=]

local Asks = require("../Machine/Asks")
local Backoff = require("../Machine/Backoff")
local Hash = require("../Encode/Hash")
local Limits = require("../Core/Constants/Limits")
local Machine = require("../Machine/Machine")

export type Context = {
	read Index: number,
	Tries: number,
}

type Call = Machine.Call<Context, number>

local STATE: {
	read Counting: "Counting",
	read Resting: "Resting",
	read Done: "Done",
} = {
	Counting = "Counting",
	Resting = "Resting",
	Done = "Done",
}

local Number = {}

local function Count(Call: Call)
	Machine.Ask(Call, Asks.Count(Call.Context.Index))
end

local function Taken(Call: Call): string
	local Context = Call.Context
	Machine.Answer(Call, (Machine.Reply(Call).Value :: number) * Limits.COUNTERS + Context.Index)
	return STATE.Done
end

local function Missed(Call: Call): string
	Call.Context.Tries += 1
	return STATE.Resting
end

local function Rest(Call: Call)
	Machine.Ask(Call, Asks.Wait(Backoff.Retry(Call.Context.Tries)))
end

local STATES: { [string]: Machine.State<Context, number> } = {
	[STATE.Counting] = {
		Enter = Count,
		On = {
			{ Said = Asks.SAID.Failed, Go = Missed },
		},
		Else = Taken,
	},
	[STATE.Resting] = {
		Enter = Rest,
		Else = STATE.Counting,
	},
	[STATE.Done] = {},
}

function Number.Context(JobId: string): Context
	return { Index = Hash(JobId) % Limits.COUNTERS, Tries = 0 }
end

Number.Machine = Machine.Define({ Name = "Number", Initial = STATE.Counting, States = STATES })

return Number
