--!strict
--!optimize 2

--[=[

	Save: Machine. Sends one key's queue until it is empty.

	Spec: record 3.2 and 6. Model: Rec.tla, Send and Hear.

	Checking looks at the queue. Empty, it answers Empty. Spent, it answers Spent, and its owner
	renews the queue's number and runs it again. Otherwise it sends. Sending sends the request
	Queue.Build makes, and Queue.Learn reads the reply. Each fate goes to its op's Tell, and a landing
	goes to Landed. A reply that lands or settles an op sends again at once. A reply that says a mark
	blocks an op runs Unblock on the first such mark, and the next request carries the end it
	answers. Any other reply rests as Backoff says, longer each time, then sends again.

	Return type: A table with Machine, Context and SAID. The type is Context.
	Example usage:
		local Said = Runner.Run(Save.Machine, Save.Context(Held, Landed), Places):Wait()
--]=]

local Asks = require("../Machine/Asks")
local Backoff = require("../Machine/Backoff")
local Blockers = require("../Record/Blockers")
local Machine = require("../Machine/Machine")
local Queue = require("../Record/Queue")
local Types = require("../Record/Types")
local Unblock = require("./Unblock")

export type Context = {
	read Queue: Queue.Queue,
	read Landed: ((Note: Types.Note) -> ())?,
	Request: Types.Request?,
	Blocker: Blockers.Blocker?,
	Idle: number,
}

type Said = "Empty" | "Spent"
type Call = Machine.Call<Context, Said>

local STATE: {
	read Checking: "Checking",
	read Sending: "Sending",
	read Unblocking: "Unblocking",
	read Resting: "Resting",
	read Done: "Done",
} = {
	Checking = "Checking",
	Sending = "Sending",
	Unblocking = "Unblocking",
	Resting = "Resting",
	Done = "Done",
}

local WORD: {
	read Empty: "Empty",
	read Spent: "Spent",
	read Moved: "Moved",
	read Blocked: "Blocked",
	read Ridden: "Ridden",
} = {
	Empty = "Empty",
	Spent = "Spent",
	Moved = "Moved",
	Blocked = "Blocked",
	Ridden = "Ridden",
}

local SAID: {
	read Empty: "Empty",
	read Spent: "Spent",
} = {
	Empty = "Empty",
	Spent = "Spent",
}

local Save = { SAID = SAID }

local function Blocked(Note: Types.Note): boolean
	for _, Why in Note.Whys do
		if Why == Types.Why.Blocked or Why == Types.Why.Overdue then
			return true
		end
	end
	return false
end

local function Check(Call: Call): string
	local Held = Call.Context.Queue
	if Held.Items[1] == nil then
		return WORD.Empty
	elseif Queue.Spent(Held) then
		return WORD.Spent
	end
	return Asks.SAID.Done
end

local function Emptied(Call: Call): string
	Call.Context.Queue.Since = Call.Now
	Machine.Answer(Call, SAID.Empty)
	return STATE.Done
end

local function Exhausted(Call: Call): string
	Machine.Answer(Call, SAID.Spent)
	return STATE.Done
end

local function Send(Call: Call)
	local Context = Call.Context
	local Held = Context.Queue
	local Request = assert(Queue.Build(Held, Call.Now), "Save: nothing to send")
	Context.Request = Request
	Machine.Ask(Call, Asks.Send(Held.Ref, Request, Held.UserIds))
end

local function Learn(Call: Call): string
	local Context = Call.Context
	local Held, Reply = Context.Queue, Machine.Reply(Call)
	local Note = Reply.Note
	local Request = assert(Context.Request, "Save: a reply with no request")
	local Fates: { Queue.Fate } = if Note then Queue.Learn(Held, Request, Note, Reply.Ran, Reply.Now) else Queue.Failed(Held)
	for _, Each in Fates do
		local Tell = Each.Item.Tell
		if Tell then
			Tell(Each.Item.Asked, Each.Reply, Each.Code)
		end
	end
	if Note and Note.Stored and Context.Landed then
		Context.Landed(Note)
	end
	local Found = if Note and Blocked(Note) then Blockers.Pick(Note.Items or {}, Held.Ref) else nil
	if Found then
		Context.Blocker = Found
		return WORD.Blocked
	elseif Note and (Note.Stored or Fates[1]) then
		Context.Idle = 0
		return WORD.Moved
	end
	Context.Idle += 1
	return Asks.SAID.Done
end

local function Help(Call: Call)
	local Context = Call.Context
	local First = Context.Queue.Items[1]
	local Stamp = if First and First.Stamp then First.Stamp else Call.Now
	local Found = assert(Context.Blocker, "Save: unblocking with no blocker")
	Machine.Ask(Call, Asks.Run(Unblock.Machine, Unblock.Context(Found, Stamp, "")))
end

local function Helped(Call: Call): string
	local Context = Call.Context
	local End = Machine.Reply(Call).Answer
	Context.Blocker = nil
	if type(End) == "table" then
		Queue.Ride(Context.Queue, End :: Types.End)
		return WORD.Ridden
	end
	Context.Idle += 1
	return Asks.SAID.Done
end

local function Rest(Call: Call)
	Machine.Ask(Call, Asks.Wait(Backoff(Call.Context.Idle)))
end

local STATES: { [string]: Machine.State<Context, Said> } = {
	[STATE.Checking] = {
		Hear = Check,
		On = {
			{ Said = WORD.Empty, Go = Emptied },
			{ Said = WORD.Spent, Go = Exhausted },
		},
		Else = STATE.Sending,
	},
	[STATE.Sending] = {
		Enter = Send,
		Hear = Learn,
		On = {
			{ Said = WORD.Blocked, Go = STATE.Unblocking },
			{ Said = WORD.Moved, Go = STATE.Checking },
		},
		Else = STATE.Resting,
	},
	[STATE.Unblocking] = {
		Enter = Help,
		Hear = Helped,
		On = {
			{ Said = WORD.Ridden, Go = STATE.Checking },
		},
		Else = STATE.Resting,
	},
	[STATE.Resting] = {
		Enter = Rest,
		Else = STATE.Checking,
	},
	[STATE.Done] = {},
}

function Save.Context(Held: Queue.Queue, Landed: ((Note: Types.Note) -> ())?): Context
	return { Queue = Held, Landed = Landed, Idle = 0 }
end

Save.Machine = Machine.Define({ Name = "Save", Initial = STATE.Checking, States = STATES })

return Save
