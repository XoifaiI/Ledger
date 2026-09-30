--!strict
--!optimize 2

--[=[

	Tx: Machine. Runs one transaction for the server that coordinates it.

	Spec: transaction 3.1, 3.5 to 3.7. Model: Tx.tla, Steps for a tx call.

	Reading, for a game name, reads the decider first: a decision that took under the call's
	fingerprint answers true, and one under another answers Spent. Tenting sends a Tent to every leg
	key but the decider, all at once. When each reports its mark, Committing sends the Commit. A
	commit answers true and resolves every leg. A fence that is not final goes again under the next
	attempt, up to Limits.ATTEMPTS. A refusal answers Refused or Full and resolves abort wherever a
	mark of the call may have landed. A step a mark blocks runs Unblock on it and rides what it
	answers on the resend. A commit that is owed verifies the pinned records it lists and sends
	again with their drops. Each of these goes round at most Limits.TRIES times. Anything else fences
	the decider with final and answers by the fence. TENT_WORDS gives the word each Tent reply says,
	and a decision that refused says Refused. When the Tents disagree, the first of TENTS they said
	decides, in the order transaction 3.6 gives.

	Return type: A table with Run, Retry and Context. The types are Leg, Use and Context.
	Example usage:
		local Reply = Runner.Run(Tx.Run, Tx.Context(Use, Legs, Decider, Server), Places):Wait()
--]=]

local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Backoff = require("../Machine/Backoff")
local Blockers = require("../Record/Blockers")
local Book = require("../Record/Book")
local Key = require("../Record/Key")
local Limits = require("../Core/Constants/Limits")
local Machine = require("../Machine/Machine")
local Queue = require("../Record/Queue")
local Types = require("../Record/Types")
local Unblock = require("./Unblock")

type Reply = Queue.Reply
type Answer = Answer.Answer

export type Leg = {
	read Ref: Book.Ref,
	read MustExist: boolean,
	read Change: Types.Leg,
}

export type Use = {
	read Name: string,
	read Stamp: number,
	read Print: number?,
}

export type Context = {
	read Use: Use,
	read Legs: { Leg },
	read Decider: number,
	read Server: number,
	Attempt: number,
	Rounds: number,
	Marked: { [number]: true },
	Landed: { [number]: true },
	Wrote: boolean,
	Rides: { [string]: { Types.End } },
	Drops: { string },
	Owed: { [string]: Book.Work },
	Sent: { number },
	Checked: { string },
	Blocker: Blockers.Blocker?,
	Back: string,
	Fallback: Answer,
	Code: number?,
	Keys: { number },
	End: Types.End?,
}

type Call = Machine.Call<Context, Reply>

local STATE: {
	read Reading: "Reading",
	read Tenting: "Tenting",
	read Committing: "Committing",
	read Fencing: "Fencing",
	read Resolving: "Resolving",
	read Verifying: "Verifying",
	read Helping: "Helping",
	read Resting: "Resting",
	read Done: "Done",
} =
	{
		Reading = "Reading",
		Tenting = "Tenting",
		Committing = "Committing",
		Fencing = "Fencing",
		Resolving = "Resolving",
		Verifying = "Verifying",
		Helping = "Helping",
		Resting = "Resting",
		Done = "Done",
	}

local WORD: {
	read Took: "Took",
	read Taken: "Taken",
	read Marked: "Marked",
	read Stuck: "Stuck",
} = {
	Took = "Took",
	Taken = "Taken",
	Marked = "Marked",
	Stuck = "Stuck",
}

local Fate = Book.Fate
local Role = Book.Role
local Report = Types.Report
local Outcome = Types.Outcome
local Why = Types.Why
local SAID = Asks.SAID

local TENTS: { string } = {
	Report.Refused,
	WORD.Marked,
	Report.Other,
	Report.Forgotten,
	Why.Missing,
	Report.Behind,
	Report.Ahead,
	WORD.Stuck,
	SAID.Failed,
}

local TENT_WORDS: { [string]: string } = {
	[Report.Mine] = WORD.Marked,
	[Report.Refused] = Report.Refused,
	[Report.Other] = Report.Other,
	[Report.Superseded] = Report.Other,
	[Report.Decided] = Report.Other,
	[Report.Large] = Report.Other,
	[Report.Forgotten] = Report.Forgotten,
	[Why.Missing] = Why.Missing,
	[Report.Behind] = Report.Behind,
	[Report.Ahead] = Report.Ahead,
	[Report.Blocked] = WORD.Stuck,
	[Report.NoRoom] = WORD.Stuck,
	[Why.Overdue] = WORD.Stuck,
}

local Tx = {}

local function Where(Ref: Book.Ref): string
	return `{Ref.Store}/{Ref.Key}`
end

local function Give(Call: Call, Result: Reply)
	if Call.Answered == nil then
		Machine.Answer(Call, Result)
	end
end

local function Refusal(Code: number?): Answer
	return if Code == Fate.Full then Answer.Full else Answer.Refused
end

local function Settle(Call: Call, Result: Types.Outcome, Attempt: number): string
	local Context = Call.Context
	local Use = Context.Use
	Context.End = { Name = Use.Name, Stamp = Use.Stamp, Attempt = Attempt, Print = Use.Print, Outcome = Result }
	table.clear(Context.Keys)
	for Index in Context.Legs do
		if Index ~= Context.Decider and (Result == Outcome.Commit or Context.Landed[Index]) then
			table.insert(Context.Keys, Index)
		end
	end
	return if Context.Keys[1] then STATE.Resolving else STATE.Done
end

local function Answered(Result: Reply): (Call: Call) -> string
	return function(Call: Call): string
		Give(Call, Result)
		return STATE.Done
	end
end

local function Committed(Call: Call): string
	local Note = Machine.Reply(Call).Note
	Give(Call, true)
	return Settle(Call, Outcome.Commit, if Note and Note.Attempt then Note.Attempt else Call.Context.Attempt)
end

local function Aborted(Result: Reply?): (Call: Call) -> string
	return function(Call: Call): string
		local Context = Call.Context
		local Note = Machine.Reply(Call).Note
		Give(Call, Result or Refusal(Context.Code or (if Note then Note.Fate else nil)))
		return Settle(Call, Outcome.Abort, Context.Attempt)
	end
end

local function Fenced(Call: Call): string
	local Fallback = Call.Context.Fallback
	local Result = if Fallback == Answer.Expired or Fallback == Answer.Missing then Answer.Spent else Fallback
	return Aborted(Result)(Call)
end

local function Clean(Fallback: Answer): (Call: Call) -> string
	return function(Call: Call): string
		local Context = Call.Context
		Context.Fallback = Fallback
		if Context.Wrote then
			return STATE.Fencing
		end
		Give(Call, Fallback)
		return STATE.Done
	end
end

local function NotFinal(Call: Call): boolean
	local Note = Machine.Reply(Call).Note
	return Note ~= nil and not Note.Final and Call.Context.Attempt < Limits.ATTEMPTS
end

local function RoundsLeft(Call: Call): boolean
	return Call.Context.Rounds < Limits.TRIES
end

local function NextAttempt(Call: Call): string
	local Context = Call.Context
	Context.Attempt += 1
	table.clear(Context.Marked)
	return STATE.Tenting
end

local function Later(Back: string): (Call: Call) -> string
	return function(Call: Call): string
		Call.Context.Back = Back
		return STATE.Resting
	end
end

local function Help(Back: string): (Call: Call) -> string
	return function(Call: Call): string
		Call.Context.Back = Back
		return STATE.Helping
	end
end

local function Stuck(Call: Call, Reply: Asks.Heard, Ref: Book.Ref): boolean
	local Note = Reply.Note
	local Items: { [string]: Book.Work } = if Note and Note.Items then Note.Items else {}
	local Found = Blockers.Pick(Items, Ref)
	Call.Context.Blocker = Found
	return Found ~= nil and RoundsLeft(Call)
end

local function Read(Call: Call)
	local Context = Call.Context
	Machine.Ask(Call, Asks.Read(Context.Legs[Context.Decider].Ref))
end

local function Took(Call: Call): string
	local Use = Call.Context.Use
	local Found = Key.Read(Machine.Reply(Call).Value)
	if type(Found) ~= "table" then
		return SAID.Done
	end
	local Item = Found.Book.Work[Use.Name]
	local Held = Found.Book:Held(Use.Name)
	local Print: number? = nil
	if Item and Item.Form == "Pinned" then
		Print = Item.Print
	elseif Held and Held.Role == Role.Decision and Held.Fate == Fate.Took then
		Print = Held.Print
	else
		return SAID.Done
	end
	return if Print == Use.Print then WORD.Took else WORD.Taken
end

local function Tent(Call: Call)
	local Context = Call.Context
	local Use, Decider = Context.Use, Context.Legs[Context.Decider]
	table.clear(Context.Sent)
	for Index, Leg in Context.Legs do
		if Index == Context.Decider or Context.Marked[Index] then
			continue
		end
		table.insert(Context.Sent, Index)
		local Request: Types.Request = {
			Writer = 0,
			Ack = 0,
			MustExist = Leg.MustExist,
			Ops = {},
			Ends = Context.Rides[Where(Leg.Ref)],
			Tent = {
				Name = Use.Name,
				Stamp = Use.Stamp,
				Attempt = Context.Attempt,
				Print = Use.Print,
				Decider = Decider.Ref,
				Leg = Leg.Change,
			},
		}
		Machine.Ask(Call, Asks.Send(Leg.Ref, Request))
	end
end

local function TentWord(Reply: Asks.Heard): string
	local Note = Reply.Note
	if Note and Note.Report == Report.Decided and (Note.Fate == Fate.Refused or Note.Fate == Fate.Full) then
		return Report.Refused
	end
	return TENT_WORDS[Reply.Said] or SAID.Failed
end

local function Tents(Call: Call): string
	local Context = Call.Context
	local Heard: { [string]: true } = {}
	for Order, Reply in Call.Heard do
		local Index = Context.Sent[Order]
		local Note = Reply.Note
		if Reply.Wrote or Note == nil then
			Context.Wrote = true
			Context.Landed[Index] = true
		end
		local Word = TentWord(Reply)
		if Word == WORD.Marked then
			Context.Marked[Index], Context.Landed[Index] = true, true
			continue
		elseif Word == WORD.Stuck and not Stuck(Call, Reply, Context.Legs[Index].Ref) then
			continue
		elseif Word == Report.Refused and Note then
			Context.Code = Note.Fate
		end
		Heard[Word] = true
	end
	local Marked = true
	for Index in Context.Legs do
		Marked = Marked and (Index == Context.Decider or Context.Marked[Index] == true)
	end
	for _, Word in TENTS do
		if Heard[Word] or (Word == WORD.Marked and Marked) then
			return Word
		end
	end
	return SAID.Done
end

local function Commit(Call: Call)
	local Context = Call.Context
	local Use = Context.Use
	local Others: { Book.Ref } = {}
	for Index, Leg in Context.Legs do
		if Index ~= Context.Decider then
			table.insert(Others, Leg.Ref)
		end
	end
	local Decider = Context.Legs[Context.Decider]
	local Request: Types.Request = {
		Writer = 0,
		Ack = 0,
		MustExist = Decider.MustExist,
		Ops = {},
		Ends = Context.Rides[Where(Decider.Ref)],
		Drops = if Context.Drops[1] then table.clone(Context.Drops) else nil,
		Commit = {
			Name = Use.Name,
			Stamp = Use.Stamp,
			Attempt = Context.Attempt,
			Print = Use.Print,
			Legs = Others,
			Leg = Decider.Change,
		},
	}
	Machine.Ask(Call, Asks.Send(Decider.Ref, Request))
end

local function Blocked(Call: Call): boolean
	local Context = Call.Context
	return Stuck(Call, Machine.Reply(Call), Context.Legs[Context.Decider].Ref)
end

local function Owed(Call: Call): string
	local Note = Machine.Reply(Call).Note
	Call.Context.Owed = if Note and Note.Items then Note.Items else {}
	return STATE.Verifying
end

local function Behind(Call: Call): string
	Call.Context.Fallback = Answer.Behind
	return STATE.Fencing
end

local function Fence(Call: Call)
	local Context = Call.Context
	local Use = Context.Use
	local Decider = Context.Legs[Context.Decider].Ref
	local Request: Types.Request = {
		Writer = 0,
		Ack = 0,
		MustExist = true,
		Ops = {},
		Ends = Context.Rides[Where(Decider)],
		Fence = { Name = Use.Name, Stamp = Use.Stamp, Attempt = Context.Attempt, Print = Use.Print, Final = true },
	}
	Machine.Ask(Call, Asks.Send(Decider, Request))
end

local function Again(Call: Call): string
	Call.Context.Rounds += 1
	return STATE.Fencing
end

local function Resolve(Call: Call)
	local Context = Call.Context
	local End = assert(Context.End, "Tx: nothing to resolve")
	for _, Index in Context.Keys do
		local Ref = Context.Legs[Index].Ref
		local Ends = table.clone(Context.Rides[Where(Ref)] or {})
		table.insert(Ends, End)
		Machine.Ask(Call, Asks.Send(Ref, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Ends = Ends }))
	end
end

local function Verify(Call: Call)
	local Context = Call.Context
	local Names: { string } = {}
	for Name, Item in Context.Owed do
		if Item.Form == "Pinned" then
			table.insert(Names, Name)
		end
	end
	table.sort(Names)
	table.clear(Context.Checked)
	local Offset = if Names[1] then Context.Server % #Names else 0
	for Index = 1, math.min(#Names, Limits.OWED_FREE) do
		local Name = Names[(Offset + Index - 1) % #Names + 1]
		local Item = Context.Owed[Name]
		if Item.Form ~= "Pinned" then
			continue
		end
		local End: Types.End = { Name = Name, Stamp = Item.Stamp, Attempt = Item.Attempt, Print = Item.Print, Outcome = Outcome.Commit }
		for _, Ref in Item.Legs do
			table.insert(Context.Checked, Name)
			Machine.Ask(Call, Asks.Send(Ref, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Ends = { End } }))
		end
	end
end

local function Verified(Call: Call): string
	local Context = Call.Context
	local Lands: { [string]: number } = {}
	for Order, Reply in Call.Heard do
		local Name = Context.Checked[Order]
		local Note = Reply.Note
		Lands[Name] = if Note and Note.Why == nil then (Lands[Name] or 0) + 1 else -math.huge
	end
	for Name, Count in Lands do
		local Item = Context.Owed[Name]
		if Item and Item.Form == "Pinned" and Count == #Item.Legs then
			table.insert(Context.Drops, Name)
		end
	end
	Context.Rounds += 1
	return SAID.Done
end

local function Unblocking(Call: Call)
	local Context = Call.Context
	local Found = assert(Context.Blocker, "Tx: helping with no blocker")
	Machine.Ask(Call, Asks.Run(Unblock.Machine, Unblock.Context(Found, Context.Use.Stamp, Context.Use.Name)))
end

local function Helped(Call: Call): string
	local Context = Call.Context
	local Found = assert(Context.Blocker, "Tx: helped with no blocker")
	local End = Machine.Reply(Call).Answer
	if type(End) == "table" then
		local Place = Where(Found.Ref)
		local Rides = Context.Rides[Place] or {}
		table.insert(Rides, End :: Types.End)
		Context.Rides[Place] = Rides
	end
	Context.Blocker = nil
	Context.Rounds += 1
	return Context.Back
end

local function Rest(Call: Call)
	Machine.Ask(Call, Asks.Wait(Backoff(Call.Context.Rounds)))
end

local function Rested(Call: Call): string
	Call.Context.Rounds += 1
	return Call.Context.Back
end

local STATES: { [string]: Machine.State<Context, Reply> } = {
	[STATE.Reading] = {
		Enter = Read,
		Hear = Took,
		On = {
			{ Said = WORD.Took, Go = Answered(true) },
			{ Said = WORD.Taken, Go = Answered(Answer.Spent) },
		},
		Else = STATE.Tenting,
	},
	[STATE.Tenting] = {
		Enter = Tent,
		Hear = Tents,
		On = {
			{ Said = Report.Refused, Go = Aborted() },
			{ Said = WORD.Marked, Go = STATE.Committing },
			{ Said = Report.Other, Go = STATE.Fencing },
			{ Said = Report.Forgotten, Go = Clean(Answer.Expired) },
			{ Said = Why.Missing, Go = Clean(Answer.Missing) },
			{ Said = Report.Behind, Go = Clean(Answer.Behind) },
			{ Said = Report.Ahead, When = RoundsLeft, Go = Later(STATE.Tenting) },
			{ Said = WORD.Stuck, Go = Help(STATE.Tenting) },
			{ Said = SAID.Failed, Go = Answered(Answer.Unresolved) },
		},
		Else = STATE.Fencing,
	},
	[STATE.Committing] = {
		Enter = Commit,
		On = {
			{ Said = Report.Committed, Go = Committed },
			{ Said = Report.Fenced, When = NotFinal, Go = NextAttempt },
			{ Said = Report.Fenced, Go = Aborted(Answer.Spent) },
			{ Said = Report.Other, Go = Aborted(Answer.Spent) },
			{ Said = Report.Refused, Go = Aborted() },
			{ Said = Report.Owed, When = RoundsLeft, Go = Owed },
			{ Said = Report.Blocked, When = Blocked, Go = Help(STATE.Committing) },
			{ Said = Why.Overdue, When = Blocked, Go = Help(STATE.Committing) },
			{ Said = Report.Ahead, When = RoundsLeft, Go = Later(STATE.Committing) },
			{ Said = Report.Behind, Go = Behind },
			{ Said = SAID.Failed, Go = Answered(Answer.Unresolved) },
		},
		Else = STATE.Fencing,
	},
	[STATE.Fencing] = {
		Enter = Fence,
		On = {
			{ Said = Report.Committed, Go = Committed },
			{ Said = Report.Fenced, Go = Fenced },
			{ Said = Report.Refused, Go = Aborted() },
			{ Said = Report.Forgotten, Go = Aborted(Answer.Unresolved) },
			{ Said = Why.Missing, When = RoundsLeft, Go = Again },
		},
		Else = Answered(Answer.Unresolved),
	},
	[STATE.Resolving] = {
		Enter = Resolve,
		Else = STATE.Done,
	},
	[STATE.Verifying] = {
		Enter = Verify,
		Hear = Verified,
		Else = STATE.Committing,
	},
	[STATE.Helping] = {
		Enter = Unblocking,
		Else = Helped,
	},
	[STATE.Resting] = {
		Enter = Rest,
		Else = Rested,
	},
	[STATE.Done] = {},
}

function Tx.Context(Use: Use, Legs: { Leg }, Decider: number, Server: number): Context
	return {
		Use = Use,
		Legs = Legs,
		Decider = Decider,
		Server = Server,
		Attempt = 1,
		Rounds = 0,
		Marked = {},
		Landed = {},
		Wrote = false,
		Rides = {},
		Drops = {},
		Owed = {},
		Sent = {},
		Checked = {},
		Back = STATE.Tenting,
		Fallback = Answer.Spent,
		Keys = {},
	}
end

Tx.Run = Machine.Define({ Name = "Tx", Initial = STATE.Tenting, States = STATES })
Tx.Retry = Machine.Define({ Name = "Tx", Initial = STATE.Reading, States = STATES })

return Tx
