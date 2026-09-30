--!strict
--!optimize 2

--[=[

	Unblock: Machine. Finds out how a mark that stands in a writer's way ends.

	Spec: transaction 4.2. Model: Tx.tla, the hread, hwait and hfence steps of Steps.

	Reading reads the mark's decider. A decision answers the end the writer carries to the mark's
	key. A mark not decided is fenced once Blockers.Due allows, after a wait while it is older and
	fresh, and the fence's report decides it. A read or fence that fails, and a decider that holds no
	value, answer nothing, and the writer asks again at its next blocked send.

	Return type: A table with Machine and Context. The type is Context.
	Example usage:
		local End = Runner.Run(Unblock.Machine, Unblock.Context(Found, Stamp, Name), Places):Wait()
--]=]

local Asks = require("../Machine/Asks")
local Blockers = require("../Record/Blockers")
local Machine = require("../Machine/Machine")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")

export type Context = {
	read Blocker: Blockers.Blocker,
	read Stamp: number,
	read Name: string,
	End: Types.End?,
}

type Call = Machine.Call<Context, Types.End>

local STATE: {
	read Reading: "Reading",
	read Waiting: "Waiting",
	read Wounding: "Wounding",
	read Done: "Done",
} = {
	Reading = "Reading",
	Waiting = "Waiting",
	Wounding = "Wounding",
	Done = "Done",
}

local WORD: {
	read Decided: "Decided",
	read Due: "Due",
	read Early: "Early",
	read Nothing: "Nothing",
} = {
	Decided = "Decided",
	Due = "Due",
	Early = "Early",
	Nothing = "Nothing",
}

local Unblock = {}

local function Judged(Call: Call, Decided: Blockers.Decision?): string
	local Context = Call.Context
	local Outcome = if Decided then Decided.Outcome else nil
	if Decided and Outcome then
		Context.End = Blockers.End(Context.Blocker, Outcome, Decided.Attempt)
		return WORD.Decided
	elseif Decided then
		return WORD.Nothing
	end
	return if Blockers.Due(Context.Blocker, Context.Stamp, Context.Name, Call.Now) then WORD.Due else WORD.Early
end

local function Read(Call: Call)
	Machine.Ask(Call, Asks.Read(Call.Context.Blocker.Item.Decider))
end

local function HearRead(Call: Call): string
	local Reply = Machine.Reply(Call)
	if Reply.Said == Asks.SAID.Failed then
		return WORD.Nothing
	end
	return Judged(Call, Blockers.Read(Reply.Value, Call.Context.Blocker))
end

local function Wait(Call: Call)
	Machine.Ask(Call, Asks.Wait(Call.Context.Blocker.Item.Stamp + Windows.SETTLE - Call.Now))
end

local function Wound(Call: Call)
	local Blocker = Call.Context.Blocker
	Machine.Ask(Call, Asks.Send(Blocker.Item.Decider, Blockers.Fence(Blocker)))
end

local function HearWound(Call: Call): string
	local Decided = Blockers.Fenced(Machine.Reply(Call).Note, Call.Context.Blocker)
	return if Decided and Decided.Outcome then Judged(Call, Decided) else WORD.Nothing
end

local function Answer(Call: Call): string
	Machine.Answer(Call, assert(Call.Context.End, "Unblock: decided with no end"))
	return STATE.Done
end

local STATES: { [string]: Machine.State<Context, Types.End> } = {
	[STATE.Reading] = {
		Enter = Read,
		Hear = HearRead,
		On = {
			{ Said = WORD.Decided, Go = Answer },
			{ Said = WORD.Due, Go = STATE.Wounding },
			{ Said = WORD.Early, Go = STATE.Waiting },
		},
		Else = STATE.Done,
	},
	[STATE.Waiting] = {
		Enter = Wait,
		Else = STATE.Wounding,
	},
	[STATE.Wounding] = {
		Enter = Wound,
		Hear = HearWound,
		On = {
			{ Said = WORD.Decided, Go = Answer },
		},
		Else = STATE.Done,
	},
	[STATE.Done] = {},
}

function Unblock.Context(Blocker: Blockers.Blocker, Stamp: number, Name: string): Context
	return { Blocker = Blocker, Stamp = Stamp, Name = Name }
end

Unblock.Machine = Machine.Define({ Name = "Unblock", Initial = STATE.Reading, States = STATES })

return Unblock
