--!strict
--!optimize 2

--[=[
	Touch: Machine. Ends one item a transaction left on a key.

	Mark reads the mark's decider, and a decision resolves the mark on its key. A mark that is not
	decided is fenced once it is FenceAfter seconds old, and the fence's report decides it. A read
	that shows the decider with no value or a seal decides nothing unless it was asked once the mark
	was Windows.ORPHAN old, and then the mark ends as an orphan. A fence that reports missing is no
	evidence, since a run may read a version from before the key was made.

	Pinned resolves the record's use as committed on every leg key, all at once, and drops the record
	on its decider once each leg key is resolved. A Resolve that reports missing proves nothing,
	since its run may have read an old version, so the machine sends that leg key a ProveGone. Only
	when every such ProveGone landed does it drop the record, with a named return of the first of
	those keys. It removes each seal it landed while the clock reads at most Windows.REMOVE_SEND past
	its rt; a seal kept longer is left over, as an erase's is. Each machine answers true once a write
	ended the item, and false when it could not.

	Return type: The Touch module, with the machines Mark and Pinned, and the Context type.
	Example usage:
		local Ended = Runner.Run(Touch.Mark, Touch.Context(Name, Item, Ref, Windows.SETTLE), Places):Wait()
--]=]

local Asks = require("../Machine/Asks")
local Blockers = require("../Record/Blockers")
local Book = require("../Record/Book")
local Machine = require("../Machine/Machine")
local Requests = require("../Record/Requests")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")

export type Context = {
	read Name: string,
	read Item: Book.Work,
	read Ref: Book.Ref,
	read FenceAfter: number,
	ReadAt: number?,
	End: Requests.End?,
	read Gone: { Book.Ref },
	read Sealed: { Book.Ref },
}

type Call = Machine.Call<Context, boolean>

local STATE = {
	Reading = "Reading" :: "Reading",
	Wounding = "Wounding" :: "Wounding",
	Resolving = "Resolving" :: "Resolving",
	Verifying = "Verifying" :: "Verifying",
	Proving = "Proving" :: "Proving",
	Dropping = "Dropping" :: "Dropping",
	Removing = "Removing" :: "Removing",
	Done = "Done" :: "Done",
}

local WORD = {
	Decided = "Decided" :: "Decided",
	Due = "Due" :: "Due",
	Ended = "Ended" :: "Ended",
	Missing = "Missing" :: "Missing",
	Sealed = "Sealed" :: "Sealed",
}

local WorkForm = Book.WorkForm
local Outcome = Requests.Outcome
local Report = Types.Report
local Why = Types.Why

local Touch = {}

local function Found(Context: Context): Blockers.Blocker
	local Mark = assert(Book.AsMark(Context.Item), "Touch: a pinned record is not a mark")
	return { Name = Context.Name, Item = Mark, Ref = Context.Ref }
end

local function Answered(Ended: boolean): (Call: Call) -> string
	return function(Call: Call): string
		Machine.Answer(Call, Ended)
		return STATE.Done
	end
end

local function Decide(Call: Call, Result: Requests.Outcome, Attempt: number, Value: number?): string
	Call.Context.End = Blockers.End(Found(Call.Context), Result, Attempt, Value)
	return WORD.Decided
end

local function Read(Call: Call)
	Call.Context.ReadAt = Call.Now
	Machine.Ask(Call, Asks.Read(Found(Call.Context).Item.Decider))
end

local function HearRead(Call: Call): string
	local Context, Reply = Call.Context, Machine.Reply(Call)
	if Reply.Said == Asks.SAID.Failed then
		return Asks.SAID.Failed
	end

	local Decided = Blockers.Read(Reply.Value, Found(Context))
	if Decided == nil then
		return if Call.Now - Context.Item.Stamp >= Context.FenceAfter then WORD.Due else Asks.SAID.Done
	end

	local Result = Decided.Outcome
	if Result then
		return Decide(Call, Result, Decided.Attempt, Decided.Value)
	end

	local ReadAt = assert(Context.ReadAt, "Touch: a read heard with no time asked")
	if Decided.Gone and Blockers.IsOrphanEvidence(Found(Context), ReadAt) then
		return Decide(Call, Outcome.Orphan, Decided.Attempt)
	end
	return Asks.SAID.Done
end

local function Wound(Call: Call)
	local Blocker = Found(Call.Context)
	Machine.Ask(Call, Asks.Send(Blocker.Item.Decider, Blockers.Fence(Blocker)))
end

local function HearWound(Call: Call): string
	local Decided = Blockers.Fenced(Machine.Reply(Call).Note, Found(Call.Context))
	local Result = if Decided then Decided.Outcome else nil
	if Decided and Result then
		return Decide(Call, Result, Decided.Attempt, Decided.Value)
	end
	return Asks.SAID.Done
end

local function Resolve(Call: Call)
	local Context = Call.Context
	local End = assert(Context.End, "Touch: nothing to resolve")
	Machine.Ask(Call, Asks.Send(Context.Ref, Requests.Ends({ End })))
end

local function Written(Call: Call): string
	local Note = Machine.Reply(Call).Note
	return if Note and Note.Why == nil then WORD.Ended else Asks.SAID.Done
end

local function Verify(Call: Call)
	local Context = Call.Context
	local Item = Context.Item
	assert(Item.Form == WorkForm.Pinned, "Touch: a mark is not a pinned record")
	local End: Requests.End = { Name = Context.Name, Stamp = Item.Stamp, Attempt = Item.Attempt, Print = Item.Print, Outcome = Outcome.Commit, Value = Item.Value }
	for _, Ref in Item.Legs do
		Machine.Ask(Call, Asks.Send(Ref, Requests.Ends({ End })))
	end
end

local function Verified(Call: Call): string
	local Context = Call.Context
	local Item = Context.Item
	assert(Item.Form == WorkForm.Pinned, "Touch: a mark is not a pinned record")
	table.clear(Context.Gone)
	for Index, Reply in Call.Heard do
		local Note = Reply.Note
		if Note == nil then
			return Asks.SAID.Done
		elseif Note.Why == Why.Missing then
			table.insert(Context.Gone, Item.Legs[Index])
		elseif Note.Why ~= nil then
			return Asks.SAID.Done
		end
	end
	return if Context.Gone[1] then WORD.Missing else WORD.Ended
end

local function Prove(Call: Call)
	for _, Ref in Call.Context.Gone do
		Machine.Ask(Call, Asks.Send(Ref, Requests.ProveGone()))
	end
end

local function Proved(Call: Call): string
	local Context = Call.Context
	table.clear(Context.Sealed)
	local Proofs = 0
	for Index, Reply in Call.Heard do
		local Note = Reply.Note
		local Seal = if Note and Note.Report == Report.Stamped then Note.Seal else nil
		if Seal then
			Proofs += 1
		end
		if Seal and Call.Now - Seal.Rt <= Windows.REMOVE_SEND then
			table.insert(Context.Sealed, Context.Gone[Index])
		end
	end
	if Proofs == #Context.Gone then
		return WORD.Ended
	end
	return if Context.Sealed[1] then WORD.Sealed else Asks.SAID.Done
end

local function RemoveSeals(Call: Call)
	for _, Ref in Call.Context.Sealed do
		Machine.Ask(Call, Asks.Remove(Ref))
	end
end

local function Drop(Call: Call)
	local Context = Call.Context
	local Gone = Context.Gone[1]
	local Request: Requests.Request = if Gone then Requests.Ends(nil, nil, { { Name = Context.Name, Ref = Gone } }) else Requests.Ends(nil, { Context.Name })
	Machine.Ask(Call, Asks.Send(Context.Ref, Request))
	RemoveSeals(Call)
end

local STATES: { [string]: Machine.State<Context, boolean> } = {
	[STATE.Reading] = {
		Enter = Read,
		Hear = HearRead,
		On = {
			{ Said = WORD.Decided, Go = STATE.Resolving },
			{ Said = WORD.Due, Go = STATE.Wounding },
		},
		Else = Answered(false),
	},
	[STATE.Wounding] = {
		Enter = Wound,
		Hear = HearWound,
		On = {
			{ Said = WORD.Decided, Go = STATE.Resolving },
		},
		Else = Answered(false),
	},
	[STATE.Resolving] = {
		Enter = Resolve,
		Hear = Written,
		On = {
			{ Said = WORD.Ended, Go = Answered(true) },
		},
		Else = Answered(false),
	},
	[STATE.Verifying] = {
		Enter = Verify,
		Hear = Verified,
		On = {
			{ Said = WORD.Ended, Go = STATE.Dropping },
			{ Said = WORD.Missing, Go = STATE.Proving },
		},
		Else = Answered(false),
	},
	[STATE.Proving] = {
		Enter = Prove,
		Hear = Proved,
		On = {
			{ Said = WORD.Ended, Go = STATE.Dropping },
			{ Said = WORD.Sealed, Go = STATE.Removing },
		},
		Else = Answered(false),
	},
	[STATE.Dropping] = {
		Enter = Drop,
		Hear = Written,
		On = {
			{ Said = WORD.Ended, Go = Answered(true) },
		},
		Else = Answered(false),
	},
	[STATE.Removing] = {
		Enter = RemoveSeals,
		Else = Answered(false),
	},
	[STATE.Done] = {},
}

function Touch.Known(Item: Book.Work, Places: { [string]: any }): boolean
	local Mark = Book.AsMark(Item)
	if Mark then
		return Places[Mark.Decider.Store] ~= nil
	end
	if Item.Form == WorkForm.Pinned then
		for _, Ref in Item.Legs do
			if Places[Ref.Store] == nil then
				return false
			end
		end
	end
	return true
end

function Touch.Context(Name: string, Item: Book.Work, Ref: Book.Ref, FenceAfter: number): Context
	return { Name = Name, Item = Item, Ref = Ref, FenceAfter = FenceAfter, Gone = {}, Sealed = {} }
end

Touch.Mark = Machine.Define({ Name = "Touch", Initial = STATE.Reading, States = STATES })
Touch.Pinned = Machine.Define({ Name = "Touch", Initial = STATE.Verifying, States = STATES })

return Touch
