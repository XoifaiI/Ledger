--!strict
--!optimize 2

--[=[
	Unblock: Machine. Finds out how a mark that stands in a writer's way ends.

	Spec: transaction 4.2. Model: Tx.tla, the hread, hwait and hfence steps of Steps.

	The machine reads the mark's decider. A decision answers the end the writer carries to the mark's
	key. A mark not decided is fenced once Blockers.Due allows. For a mark older than the writer's
	op, that is after a wait until the mark is Windows.SETTLE old. The fence's report then decides
	it. A read or a fence that fails answers nothing, and so does a decider that holds no value or a
	seal, until a read asked Windows.ORPHAN past the mark's stamp shows it. That read is the orphan
	evidence of transaction 5.1, and the machine answers the mark's orphan end. A fence that says
	missing is not evidence, since a run may read an old version. The writer asks again at its next
	blocked send.

	Return type: The Unblock module, and the Context type.
	Example usage:
		local End = Runner.Run(Unblock.Machine, Unblock.Context(Found, Stamp, Name), Places):Wait()
--]=]

local Asks = require("../Machine/Asks")
local Blockers = require("../Record/Blockers")
local Machine = require("../Machine/Machine")
local Requests = require("../Record/Requests")
local Windows = require("../Core/Constants/Windows")

export type Context = {
	read Blocker: Blockers.Blocker,
	read Stamp: number,
	read Name: string,
	ReadAt: number?,
	End: Requests.End?,
}

type Call = Machine.Call<Context, Requests.End>

local STATE = {
	Reading = "Reading" :: "Reading",
	Waiting = "Waiting" :: "Waiting",
	Wounding = "Wounding" :: "Wounding",
	Done = "Done" :: "Done",
}

local WORD = {
	Decided = "Decided" :: "Decided",
	Due = "Due" :: "Due",
	Early = "Early" :: "Early",
	Nothing = "Nothing" :: "Nothing",
}

local Unblock = {}

local function Judged(Call: Call, Decided: Blockers.Decision?): string
	local Context = Call.Context
	local Outcome = if Decided then Decided.Outcome else nil
	if Decided and Outcome then
		Context.End = Blockers.End(Context.Blocker, Outcome, Decided.Attempt, Decided.Value)
		return WORD.Decided
	elseif Decided then
		return WORD.Nothing
	end
	return if Blockers.Due(Context.Blocker, Context.Stamp, Context.Name, Call.Now) then WORD.Due else WORD.Early
end

local function Read(Call: Call)
	Call.Context.ReadAt = Call.Now
	Machine.Ask(Call, Asks.Read(Call.Context.Blocker.Item.Decider))
end

local function HearRead(Call: Call): string
	local Context, Reply = Call.Context, Machine.Reply(Call)
	if Reply.Said == Asks.SAID.Failed then
		return WORD.Nothing
	end
	local Decided = Blockers.Read(Reply.Value, Context.Blocker)
	local ReadAt = assert(Context.ReadAt, "Unblock: a read heard with no time asked")
	if Decided and Decided.Gone and Blockers.IsOrphanEvidence(Context.Blocker, ReadAt) then
		Context.End = Blockers.End(Context.Blocker, Requests.Outcome.Orphan, Decided.Attempt)
		return WORD.Decided
	end
	return Judged(Call, Decided)
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

local STATES: { [string]: Machine.State<Context, Requests.End> } = {
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
