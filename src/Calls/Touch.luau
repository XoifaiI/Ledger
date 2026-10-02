--!strict
--!optimize 2

--[=[

	Touch: Machine. Ends one item a transaction left on a key.

	Spec: transaction 5.1. Model: Tx.tla, the tread and tver steps of Steps.

	Mark reads the mark's decider. A decision resolves the mark on its key by that decision. A mark
	that is not decided is fenced once it is FenceAfter seconds old, and the fence's report decides
	it. A decider that holds no value decides nothing until the mark is Windows.ORPHAN old, and then
	the mark ends as an orphan. Pinned resolves the record's use as committed on every leg key, all
	at once. It drops the record on its decider once each leg key is resolved or reads gone past
	Windows.ORPHAN. The drop carries a named return of the first leg key that read gone. Each
	answers true once a write ended the item, and false when it could not. Known says whether this
	server knows the store of every other key an item names.

	Return type: A table with Mark, Pinned, Known and Context. The type is Context.
	Example usage:
		local Ended = Runner.Run(Touch.Mark, Touch.Context(Name, Item, Ref, Windows.SETTLE), Places):Wait()
--]=]

local Asks = require("../Machine/Asks")
local Blockers = require("../Record/Blockers")
local Book = require("../Record/Book")
local Machine = require("../Machine/Machine")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")

export type Context = {
	read Name: string,
	read Item: Book.Work,
	read Ref: Book.Ref,
	read FenceAfter: number,
	End: Types.End?,
	Gone: Book.Ref?,
}

type Call = Machine.Call<Context, boolean>

local STATE: {
	read Reading: "Reading",
	read Wounding: "Wounding",
	read Resolving: "Resolving",
	read Verifying: "Verifying",
	read Dropping: "Dropping",
	read Done: "Done",
} = {
	Reading = "Reading",
	Wounding = "Wounding",
	Resolving = "Resolving",
	Verifying = "Verifying",
	Dropping = "Dropping",
	Done = "Done",
}

local WORD: {
	read Decided: "Decided",
	read Due: "Due",
	read Ended: "Ended",
} = {
	Decided = "Decided",
	Due = "Due",
	Ended = "Ended",
}

local Outcome = Types.Outcome

local Touch = {}

local function Found(Context: Context): Blockers.Blocker
	local Item = Context.Item
	assert(Item.Form ~= "Pinned", "Touch: a pinned record is not a mark")
	return { Name = Context.Name, Item = Item, Ref = Context.Ref }
end

local function Old(Call: Call): boolean
	return Call.Now - Call.Context.Item.Stamp >= Windows.ORPHAN
end

local function Answered(Ended: boolean): (Call: Call) -> string
	return function(Call: Call): string
		Machine.Answer(Call, Ended)
		return STATE.Done
	end
end

local function Judge(Call: Call, Decided: Blockers.Decision?): string
	local Context = Call.Context
	local Result = if Decided then Decided.Outcome else nil
	if Decided and Result then
		Context.End = Blockers.End(Found(Context), Result, Decided.Attempt, Decided.Value)
		return WORD.Decided
	elseif Decided and Decided.Gone and Old(Call) then
		Context.End = Blockers.End(Found(Context), Outcome.Orphan, Decided.Attempt)
		return WORD.Decided
	end
	return Asks.SAID.Done
end

local function Read(Call: Call)
	Machine.Ask(Call, Asks.Read(Found(Call.Context).Item.Decider))
end

local function HearRead(Call: Call): string
	local Reply = Machine.Reply(Call)
	if Reply.Said == Asks.SAID.Failed then
		return Asks.SAID.Failed
	end
	local Decided = Blockers.Read(Reply.Value, Found(Call.Context))
	if Decided then
		return Judge(Call, Decided)
	end
	return if Call.Now - Call.Context.Item.Stamp >= Call.Context.FenceAfter then WORD.Due else Asks.SAID.Done
end

local function Wound(Call: Call)
	local Blocker = Found(Call.Context)
	Machine.Ask(Call, Asks.Send(Blocker.Item.Decider, Blockers.Fence(Blocker)))
end

local function HearWound(Call: Call): string
	return Judge(Call, Blockers.Fenced(Machine.Reply(Call).Note, Found(Call.Context)))
end

local function Resolve(Call: Call)
	local Context = Call.Context
	local End = assert(Context.End, "Touch: nothing to resolve")
	Machine.Ask(Call, Asks.Send(Context.Ref, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Ends = { End } }))
end

local function Written(Call: Call): string
	local Note = Machine.Reply(Call).Note
	return if Note and Note.Why == nil then WORD.Ended else Asks.SAID.Done
end

local function Verify(Call: Call)
	local Context = Call.Context
	local Item = Context.Item
	assert(Item.Form == "Pinned", "Touch: a mark is not a pinned record")
	local End: Types.End = { Name = Context.Name, Stamp = Item.Stamp, Attempt = Item.Attempt, Print = Item.Print, Outcome = Outcome.Commit, Value = Item.Value }
	for _, Ref in Item.Legs do
		Machine.Ask(Call, Asks.Send(Ref, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Ends = { End } }))
	end
end

local function Verified(Call: Call): string
	local Context = Call.Context
	local Item = Context.Item
	assert(Item.Form == "Pinned", "Touch: a mark is not a pinned record")
	Context.Gone = nil
	for Index, Reply in Call.Heard do
		local Note = Reply.Note
		local Gone = Note ~= nil and Note.Why == Types.Why.Missing and Old(Call)
		if Note == nil or (Note.Why ~= nil and not Gone) then
			return Asks.SAID.Done
		elseif Gone and Context.Gone == nil then
			Context.Gone = Item.Legs[Index]
		end
	end
	return WORD.Ended
end

local function Drop(Call: Call)
	local Context = Call.Context
	local Gone = Context.Gone
	local Request: Types.Request = if Gone
		then { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Orphans = { { Name = Context.Name, Ref = Gone } } }
		else { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Drops = { Context.Name } }
	Machine.Ask(Call, Asks.Send(Context.Ref, Request))
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
	[STATE.Done] = {},
}

function Touch.Known(Item: Book.Work, Places: { [string]: any }): boolean
	if Item.Form ~= "Pinned" then
		return Places[Item.Decider.Store] ~= nil
	end
	for _, Ref in Item.Legs do
		if Places[Ref.Store] == nil then
			return false
		end
	end
	return true
end

function Touch.Context(Name: string, Item: Book.Work, Ref: Book.Ref, FenceAfter: number): Context
	return { Name = Name, Item = Item, Ref = Ref, FenceAfter = FenceAfter }
end

Touch.Mark = Machine.Define({ Name = "Touch", Initial = STATE.Reading, States = STATES })
Touch.Pinned = Machine.Define({ Name = "Touch", Initial = STATE.Verifying, States = STATES })

return Touch
