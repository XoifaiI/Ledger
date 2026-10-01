--!strict
--!optimize 2

--[=[

	Save: Machine. Sends one key's queue until it is empty.

	Spec: record 3.2 and 6. Model: Rec.tla, Send and Hear.

	Checking looks at the queue. Empty, it answers Empty. Spent, it answers Spent, and its owner
	renews the queue's number and runs it again. A paced queue waits out its gap. A queue that does not know the key's incarnation
	reads the key first, and a read that fails rests. Otherwise it sends. Sending sends the request
	Queue.Build makes, and Queue.Learn reads the reply. Each fate goes to its op's Tell, and a landing
	goes to Landed. A reply that lands or settles an op sends again at once. A reply that says an
	item blocks an op, or is overdue, picks one of the items it lists by the writer's number. A mark
	runs Unblock, and the next request carries the end it answers. A pinned record runs Touch, which
	verifies and drops it, and the op is sent again. A reply that meets a seal an erase left over runs
	Unseal, which takes it off. A landing on a paced queue moves its gap. Any other reply rests as
	Backoff says, or from Windows.RETRY_GAP doubling to Windows.RETRY_MAX on a paced queue, then sends
	again.

	Return type: A table with Machine, Context and SAID. The type is Context.
	Example usage:
		local Said = Runner.Run(Save.Machine, Save.Context(Held, Landed), Places):Wait()
--]=]

local Asks = require("../Machine/Asks")
local Backoff = require("../Machine/Backoff")
local Blockers = require("../Record/Blockers")
local Machine = require("../Machine/Machine")
local Queue = require("../Record/Queue")
local Touch = require("./Touch")
local Types = require("../Record/Types")
local Unblock = require("./Unblock")
local Unseal = require("./Unseal")
local Value = require("../Encode/Value")
local Windows = require("../Core/Constants/Windows")

export type Context = {
	read Queue: Queue.Queue,
	read Landed: ((Note: Types.Note) -> ())?,
	Request: Types.Request?,
	Blocker: Blockers.Found?,
	Idle: number,
}

type Said = "Empty" | "Spent"
type Call = Machine.Call<Context, Said>

local STATE: {
	read Checking: "Checking",
	read Learning: "Learning",
	read Pacing: "Pacing",
	read Sending: "Sending",
	read Unblocking: "Unblocking",
	read Unsealing: "Unsealing",
	read Resting: "Resting",
	read Done: "Done",
} =
	{
		Checking = "Checking",
		Learning = "Learning",
		Pacing = "Pacing",
		Sending = "Sending",
		Unblocking = "Unblocking",
		Unsealing = "Unsealing",
		Resting = "Resting",
		Done = "Done",
	}

local WORD: {
	read Empty: "Empty",
	read Spent: "Spent",
	read Unknown: "Unknown",
	read Paced: "Paced",
	read Known: "Known",
	read Moved: "Moved",
	read Blocked: "Blocked",
	read Helped: "Helped",
	read Left: "Left",
} =
	{
		Empty = "Empty",
		Spent = "Spent",
		Unknown = "Unknown",
		Paced = "Paced",
		Known = "Known",
		Moved = "Moved",
		Blocked = "Blocked",
		Helped = "Helped",
		Left = "Left",
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
	elseif Queue.Unknown(Held) then
		return WORD.Unknown
	elseif Queue.Wait(Held, Call.Now) > 0 then
		return WORD.Paced
	end
	return Asks.SAID.Done
end

local function Pace(Call: Call)
	Machine.Ask(Call, Asks.Wait(Queue.Wait(Call.Context.Queue, Call.Now)))
end

local function Look(Call: Call)
	Machine.Ask(Call, Asks.Read(Call.Context.Queue.Ref))
end

local function Seen(Call: Call): string
	local Reply = Machine.Reply(Call)
	if Reply.Said == Asks.SAID.Failed then
		Call.Context.Idle += 1
		return Asks.SAID.Done
	end
	Queue.Know(Call.Context.Queue, Reply.Value)
	return WORD.Known
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
	if Note and Note.Stored and Held.Pace then
		Queue.Paced(Held, Note.Writes, Value.Check(Note.Stored) or 0, Reply.Now)
	end
	if Note and Note.Stored and Context.Landed then
		Context.Landed(Note)
	end
	local Found = if Note and Blocked(Note) then Blockers.Pick(Note.Items or {}, Held.Ref, Held.Id) else nil
	if Note and Note.Left then
		return WORD.Left
	elseif Found then
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
	local Item, Mark = Found.Item, Blockers.Mark(Found)
	if Mark then
		Machine.Ask(Call, Asks.Run(Unblock.Machine, Unblock.Context(Mark, Stamp, "")))
	else
		Machine.Ask(Call, Asks.Run(Touch.Pinned, Touch.Context(Found.Name, Item, Found.Ref, Windows.SETTLE)))
	end
end

local function Helped(Call: Call): string
	local Context = Call.Context
	local End = Machine.Reply(Call).Answer
	Context.Blocker = nil
	if type(End) == "table" then
		Queue.Ride(Context.Queue, End :: Types.End)
		return WORD.Helped
	elseif End == true then
		return WORD.Helped
	end
	Context.Idle += 1
	return Asks.SAID.Done
end

local function Clear(Call: Call)
	local Held = Call.Context.Queue
	Machine.Ask(Call, Asks.Run(Unseal.Machine, Unseal.Context(Held.Ref, Held.Id, nil)))
end

local function Rest(Call: Call)
	local Context = Call.Context
	local Idle = Context.Idle
	local Wait = if Context.Queue.Pace then Backoff.Retry(Idle, Windows.RETRY_GAP, Windows.RETRY_MAX) else Backoff.Retry(Idle)
	Machine.Ask(Call, Asks.Wait(Wait))
end

local STATES: { [string]: Machine.State<Context, Said> } = {
	[STATE.Checking] = {
		Hear = Check,
		On = {
			{ Said = WORD.Empty, Go = Emptied },
			{ Said = WORD.Spent, Go = Exhausted },
			{ Said = WORD.Unknown, Go = STATE.Learning },
			{ Said = WORD.Paced, Go = STATE.Pacing },
		},
		Else = STATE.Sending,
	},
	[STATE.Pacing] = {
		Enter = Pace,
		Else = STATE.Checking,
	},
	[STATE.Learning] = {
		Enter = Look,
		Hear = Seen,
		On = {
			{ Said = WORD.Known, Go = STATE.Sending },
		},
		Else = STATE.Resting,
	},
	[STATE.Sending] = {
		Enter = Send,
		Hear = Learn,
		On = {
			{ Said = WORD.Blocked, Go = STATE.Unblocking },
			{ Said = WORD.Left, Go = STATE.Unsealing },
			{ Said = WORD.Moved, Go = STATE.Checking },
		},
		Else = STATE.Resting,
	},
	[STATE.Unblocking] = {
		Enter = Help,
		Hear = Helped,
		On = {
			{ Said = WORD.Helped, Go = STATE.Checking },
		},
		Else = STATE.Resting,
	},
	[STATE.Unsealing] = {
		Enter = Clear,
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
