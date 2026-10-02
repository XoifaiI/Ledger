--!strict
--!optimize 2

--[=[
	Tx: Machine. Runs one transaction for the server that coordinates it.

	Spec: transaction 3.1, 3.5 to 3.7. Model: Tx.tla, Steps for a tx call.

	Retry, for a game name, reads the decider first: a decision that took under the call's
	fingerprint answers true, and one under another answers Spent. A Tent goes to every leg key but
	the decider, all at once, and the Commit goes only when each reported its mark. When the Tents
	disagree, the first word of TENTS they said decides, in the order transaction 3.6 gives. A fence
	that is not final goes again under the next attempt, up to ATTEMPTS. The call answers once, and
	the machine runs on to resolve. A commit resolves every leg key. A refusal resolves abort
	wherever a mark of the call may have landed. Any reply the rows do not name fences the decider
	with final, and the fence answers the call.

	On an erasable store each Tent and Commit carries the key's id, or a create of the call's fresh
	id where the key read absent. It carries the fresh id itself once a request of the call to that
	key may have written. A step that an item blocks picks one item by the server's number. A mark
	runs Unblock, and its answer rides on the resend. A pinned record runs Touch. A step that meets a
	cut's gate waits until the gate is Windows.SETTLE old, then finishes that cut as its helper. A
	commit that is owed verifies the pinned records it lists, and sends again with their drops. Each
	of these goes round at most Limits.TRIES times. Verdict keeps the last note the decider gave a
	Commit or a Fence, and Value the decider value, for a machine that ran this one to read.

	Return type: The Tx module, with the machines Run and Retry, and the Leg, Use and Context types.
	Example usage:
		local Reply = Runner.Run(Tx.Run, Tx.Context(Use, Legs, Decider, Server), Places):Wait()
--]=]

local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Backoff = require("../Machine/Backoff")
local Blockers = require("../Record/Blockers")
local Book = require("../Record/Book")
local Cut = require("./Cut")
local Key = require("../Record/Key")
local Limits = require("../Core/Constants/Limits")
local Machine = require("../Machine/Machine")
local Queue = require("../Record/Queue")
local Requests = require("../Record/Requests")
local Touch = require("./Touch")
local Types = require("../Record/Types")
local Unblock = require("./Unblock")
local Windows = require("../Core/Constants/Windows")

type Reply = Queue.Reply
type Answer = Answer.Answer

export type Leg = {
	read Ref: Book.Ref,
	read MustExist: boolean,
	read Erasable: boolean?,
	read Change: Requests.Leg,
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
	Rides: { [string]: { Requests.End } },
	Drops: { string },
	Owed: { [string]: Book.Work },
	Sent: { number },
	Checked: { string },
	Blocker: Blockers.Found?,
	Back: string,
	Fallback: Answer,
	Code: number?,
	Keys: { number },
	End: Requests.End?,
	Ids: { [number]: string | false },
	read Fresh: string,
	Learned: { number },
	Gate: Book.Gate?,
	Gated: number?,
	Refuser: number?,
	Verdict: Types.Note?,
	Value: number?,
}

type Call = Machine.Call<Context, Reply>

local STATE = {
	Reading = "Reading" :: "Reading",
	Learning = "Learning" :: "Learning",
	Tenting = "Tenting" :: "Tenting",
	Committing = "Committing" :: "Committing",
	Fencing = "Fencing" :: "Fencing",
	Resolving = "Resolving" :: "Resolving",
	Verifying = "Verifying" :: "Verifying",
	Helping = "Helping" :: "Helping",
	Gating = "Gating" :: "Gating",
	Finishing = "Finishing" :: "Finishing",
	Resting = "Resting" :: "Resting",
	Done = "Done" :: "Done",
}

local WORD = {
	Took = "Took" :: "Took",
	Taken = "Taken" :: "Taken",
	Marked = "Marked" :: "Marked",
	Stuck = "Stuck" :: "Stuck",
	Gated = "Gated" :: "Gated",
}

local WorkForm = Book.WorkForm
local Fate = Book.Fate
local Role = Book.Role
local Report = Types.Report
local Outcome = Requests.Outcome
local Why = Types.Why
local SAID = Asks.SAID

local TENTS: { string } = {
	Report.Refused,
	WORD.Marked,
	Report.Other,
	Report.Forgotten,
	Why.Missing,
	WORD.Gated,
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
	[Report.Gated] = WORD.Gated,
}

local ATTEMPTS = 3
local OWED_FREE = 8

local Tx = { ATTEMPTS = ATTEMPTS }

local function Give(Call: Call, Result: Reply)
	if Call.Answered == nil then
		Machine.Answer(Call, Result)
	end
end

local function Refusal(Code: number?): Answer
	return if Code == Fate.Full then Answer.Full else Answer.Refused
end

local function Settle(Call: Call, Result: Requests.Outcome, Attempt: number): string
	local Context = Call.Context
	local Use = Context.Use
	Context.End = { Name = Use.Name, Stamp = Use.Stamp, Attempt = Attempt, Print = Use.Print, Outcome = Result, Value = Context.Value }
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
	return Note ~= nil and not Note.Final and Call.Context.Attempt < ATTEMPTS
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
	local Found = Blockers.Pick(Items, Ref, Call.Context.Server)
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
	if Item and Item.Form == WorkForm.Pinned then
		Print = Item.Print
		Call.Context.Value = Item.Value
	elseif Held and Held.Role == Role.Decision and Held.Fate == Fate.Took then
		Print = Held.Print
		Call.Context.Value = Held.Value
	else
		return SAID.Done
	end
	return if Print == Use.Print then WORD.Took else WORD.Taken
end

local function Incarnation(Context: Context, Index: number): (string?, string?)
	local Seen = Context.Ids[Index]
	if not Context.Legs[Index].Erasable or Seen == nil or Seen == "" then
		return nil, nil
	elseif Seen == false then
		if Context.Landed[Index] then
			return Context.Fresh, nil
		end
		return nil, Context.Fresh
	end
	return Seen, nil
end

local function Learn(Call: Call)
	local Context = Call.Context
	table.clear(Context.Learned)
	for Index, Leg in Context.Legs do
		if Leg.Erasable and Context.Ids[Index] == nil then
			table.insert(Context.Learned, Index)
			Machine.Ask(Call, Asks.Read(Leg.Ref))
		end
	end
end

local function Learned(Call: Call): string
	local Context = Call.Context
	for Order, Reply in Call.Heard do
		if Reply.Said == SAID.Failed then
			return SAID.Failed
		end
		local Found = Key.Read(Reply.Value)
		local Index = Context.Learned[Order]
		if Found == nil or Found == Why.Missing then
			Context.Ids[Index] = false
		elseif type(Found) == "table" then
			Context.Ids[Index] = Found.Book.Id or ""
		else
			Context.Ids[Index] = ""
		end
	end
	return SAID.Done
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
		local Id, Create = Incarnation(Context, Index)
		local Step: Requests.Tent = {
			Name = Use.Name,
			Stamp = Use.Stamp,
			Attempt = Context.Attempt,
			Print = Use.Print,
			Decider = Decider.Ref,
			Leg = Leg.Change,
			Id = Id,
			Create = Create,
		}
		Machine.Ask(Call, Asks.Send(Leg.Ref, Requests.Tent(Step, Leg.MustExist, Context.Rides[Book.Address(Leg.Ref)])))
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
			Context.Marked[Index] = true
			Context.Landed[Index] = true
			continue
		elseif Word == WORD.Stuck and not Stuck(Call, Reply, Context.Legs[Index].Ref) then
			continue
		elseif Word == Report.Refused and Note then
			Context.Code = Note.Fate
			Context.Refuser = Index
		elseif Word == WORD.Gated and Note then
			Context.Gate = Note.Gate
			Context.Gated = Index
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
	local Id, Create = Incarnation(Context, Context.Decider)
	local Step: Requests.Commit = {
		Name = Use.Name,
		Stamp = Use.Stamp,
		Attempt = Context.Attempt,
		Print = Use.Print,
		Legs = Others,
		Leg = Decider.Change,
		Id = Id,
		Create = Create,
	}
	local Drops = if Context.Drops[1] then table.clone(Context.Drops) else nil
	Machine.Ask(Call, Asks.Send(Decider.Ref, Requests.Commit(Step, Decider.MustExist, Context.Rides[Book.Address(Decider.Ref)], Drops)))
end

local function Committing(Call: Call): string
	local Context = Call.Context
	local Reply = Machine.Reply(Call)
	local Note = Reply.Note
	if Reply.Wrote or Note == nil then
		Context.Landed[Context.Decider] = true
	end
	Context.Verdict = Note or Context.Verdict
	Context.Value = if Note and Note.Value then Note.Value else Context.Value
	if Note and Note.Report == Report.Refused then
		Context.Refuser = Context.Decider
	end
	if Note and Note.Report == Report.Gated then
		Context.Gate = Note.Gate
		Context.Gated = Context.Decider
	end
	return Reply.Said
end

local function Gate(Back: string): (Call: Call) -> string
	return function(Call: Call): string
		Call.Context.Back = Back
		return STATE.Gating
	end
end

local function Settling(Call: Call)
	local Gate = assert(Call.Context.Gate, "Tx: gating with no gate")
	Machine.Ask(Call, Asks.Wait(Gate.At + Windows.SETTLE - Call.Now))
end

local function Finish(Call: Call)
	local Context = Call.Context
	local Gate = assert(Context.Gate, "Tx: finishing with no gate")
	local Index = assert(Context.Gated, "Tx: finishing with no gated leg")
	local Leg = Context.Legs[Index]
	local Helper: Requests.Cut = { Name = Gate.Name, Stamp = Gate.Stamp, Kind = Gate.Kind, Print = Gate.Print, Helper = true, Server = Context.Server }
	local Other = Cut.Context(Leg.Ref, Helper, Leg.Erasable == true)
	local Seen = Context.Ids[Index]
	Other.Seen = if Seen == nil then nil else Seen
	Machine.Ask(Call, Asks.Run(Cut.Machine, Other))
end

local function Finished(Call: Call): string
	local Context = Call.Context
	Context.Gate = nil
	Context.Gated = nil
	Context.Rounds += 1
	return Context.Back
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
	local Step: Requests.Fence = { Name = Use.Name, Stamp = Use.Stamp, Attempt = Context.Attempt, Print = Use.Print, Final = true }
	Machine.Ask(Call, Asks.Send(Decider, Requests.Fence(Step, Context.Rides[Book.Address(Decider)])))
end

local function Ruled(Call: Call): string
	local Context, Reply = Call.Context, Machine.Reply(Call)
	local Note = Reply.Note
	Context.Verdict = Note or Context.Verdict
	Context.Value = if Note and Note.Value then Note.Value else Context.Value
	return Reply.Said
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
		local Ends = table.clone(Context.Rides[Book.Address(Ref)] or {})
		table.insert(Ends, End)
		Machine.Ask(Call, Asks.Send(Ref, Requests.Ends(Ends)))
	end
end

local function Verify(Call: Call)
	local Context = Call.Context
	local Names: { string } = {}
	for Name, Item in Context.Owed do
		if Item.Form == WorkForm.Pinned then
			table.insert(Names, Name)
		end
	end
	table.sort(Names)
	table.clear(Context.Checked)
	local Offset = if Names[1] then Context.Server % #Names else 0
	for Index = 1, math.min(#Names, OWED_FREE) do
		local Name = Names[(Offset + Index - 1) % #Names + 1]
		local Item = Context.Owed[Name]
		if Item.Form ~= WorkForm.Pinned then
			continue
		end
		local End: Requests.End = { Name = Name, Stamp = Item.Stamp, Attempt = Item.Attempt, Print = Item.Print, Outcome = Outcome.Commit, Value = Item.Value }
		for _, Ref in Item.Legs do
			table.insert(Context.Checked, Name)
			Machine.Ask(Call, Asks.Send(Ref, Requests.Ends({ End })))
		end
	end
end

local function Verified(Call: Call): string
	local Context = Call.Context
	local Landed: { [string]: number } = {}
	local Missed: { [string]: true } = {}
	for Order, Reply in Call.Heard do
		local Name = Context.Checked[Order]
		local Note = Reply.Note
		Landed[Name] = Landed[Name] or 0
		if Note and Note.Why == nil then
			Landed[Name] += 1
		else
			Missed[Name] = true
		end
	end
	for Name, Count in Landed do
		local Item = Context.Owed[Name]
		if Item and Item.Form == WorkForm.Pinned and not Missed[Name] and Count == #Item.Legs then
			table.insert(Context.Drops, Name)
		end
	end
	Context.Rounds += 1
	return SAID.Done
end

local function Unblocking(Call: Call)
	local Context = Call.Context
	local Found = assert(Context.Blocker, "Tx: helping with no blocker")
	local Mark = Blockers.Mark(Found)
	if Mark then
		Machine.Ask(Call, Asks.Run(Unblock.Machine, Unblock.Context(Mark, Context.Use.Stamp, Context.Use.Name)))
	else
		Machine.Ask(Call, Asks.Run(Touch.Pinned, Touch.Context(Found.Name, Found.Item, Found.Ref, Windows.SETTLE)))
	end
end

local function Helped(Call: Call): string
	local Context = Call.Context
	local Found = assert(Context.Blocker, "Tx: helped with no blocker")
	local End = Machine.Reply(Call).Answer
	if type(End) == "table" then
		local Place = Book.Address(Found.Ref)
		local Rides = Context.Rides[Place] or {}
		table.insert(Rides, End :: Requests.End)
		Context.Rides[Place] = Rides
	end
	Context.Blocker = nil
	Context.Rounds += 1
	return Context.Back
end

local function Rest(Call: Call)
	Machine.Ask(Call, Asks.Wait(Backoff.Retry(Call.Context.Rounds)))
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
		Else = STATE.Learning,
	},
	[STATE.Learning] = {
		Enter = Learn,
		Hear = Learned,
		On = {
			{ Said = SAID.Failed, Go = Answered(Answer.Unresolved) },
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
			{ Said = WORD.Gated, When = RoundsLeft, Go = Gate(STATE.Tenting) },
			{ Said = SAID.Failed, Go = Answered(Answer.Unresolved) },
		},
		Else = STATE.Fencing,
	},
	[STATE.Committing] = {
		Enter = Commit,
		Hear = Committing,
		On = {
			{ Said = Report.Committed, Go = Committed },
			{ Said = Report.Fenced, When = NotFinal, Go = NextAttempt },
			{ Said = Report.Fenced, Go = Aborted(Answer.Spent) },
			{ Said = Report.Other, Go = Aborted(Answer.Spent) },
			{ Said = Report.Refused, Go = Aborted() },
			{ Said = Report.Owed, When = RoundsLeft, Go = Owed },
			{ Said = Report.Blocked, When = Blocked, Go = Help(STATE.Committing) },
			{ Said = Why.Overdue, When = Blocked, Go = Help(STATE.Committing) },
			{ Said = Report.Gated, When = RoundsLeft, Go = Gate(STATE.Committing) },
			{ Said = Report.Ahead, When = RoundsLeft, Go = Later(STATE.Committing) },
			{ Said = Report.Behind, Go = Behind },
			{ Said = SAID.Failed, Go = Answered(Answer.Unresolved) },
		},
		Else = STATE.Fencing,
	},
	[STATE.Fencing] = {
		Enter = Fence,
		Hear = Ruled,
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
	[STATE.Gating] = {
		Enter = Settling,
		Else = STATE.Finishing,
	},
	[STATE.Finishing] = {
		Enter = Finish,
		Else = Finished,
	},
	[STATE.Done] = {},
}

function Tx.Context(Use: Use, Legs: { Leg }, Decider: number, Server: number, Ids: { [number]: string | false }?, Fresh: string?): Context
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
		Ids = Ids or {},
		Fresh = Fresh or Book.Incarnation(Server, 0),
		Learned = {},
	}
end

Tx.Run = Machine.Define({ Name = "Tx", Initial = STATE.Learning, States = STATES })
Tx.Retry = Machine.Define({ Name = "Tx", Initial = STATE.Reading, States = STATES })

return Tx
