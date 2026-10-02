--!strict
--!optimize 2

--[=[
	Peek: Machine. Shows a key's state, never older than this server showed before.

	Spec: record 5.3; transaction 4.3. Model: Rec.tla, StartRead and ReadHear.

	Cached starts with a read. Fresh starts with a fresh read, an update that decides nothing and
	lands, so it is always current. A read the shown table does not allow goes on to a fresh read. A
	view with marks whose clean flag is off reads their deciders, all at once. When none committed,
	the view is shown. When some did, a fresh read that carries their resolves lands, and its view is
	shown. A decider read or a request that fails shows Unresolved.

	Return type: The Peek module, with the machines Cached and Fresh, and the Context type.
	Example usage:
		local Shown = Runner.Run(Peek.Cached, Peek.Context(Ref, Build, Table), Places):Wait()
--]=]

local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Blockers = require("../Record/Blockers")
local Book = require("../Record/Book")
local Machine = require("../Machine/Machine")
local Requests = require("../Record/Requests")
local Shown = require("../Record/Shown")
local Types = require("../Record/Types")
local View = require("../Record/View")

type Result = View.View | Answer.Answer

export type Context = {
	read Ref: Book.Ref,
	read Mark: string,
	read Build: Types.Build,
	read Shown: Shown.Shown,
	Found: Result,
	Checks: { Blockers.Blocker },
	Commits: { Requests.End },
}

type Call = Machine.Call<Context, Result>

local STATE = {
	Reading = "Reading" :: "Reading",
	Refreshing = "Refreshing" :: "Refreshing",
	Checking = "Checking" :: "Checking",
	Resolving = "Resolving" :: "Resolving",
	Done = "Done" :: "Done",
}

local WORD = {
	Stale = "Stale" :: "Stale",
	Unclean = "Unclean" :: "Unclean",
	Committed = "Committed" :: "Committed",
}

local STOPS: { [Types.Why]: Answer.Answer } = {
	[Types.Why.Missing] = Answer.Missing,
	[Types.Why.Behind] = Answer.Behind,
	[Types.Why.Worn] = Answer.Worn,
}

local Peek = {}

local function Unclean(Context: Context, Found: View.View): { Blockers.Blocker }
	local Marks: { Blockers.Blocker } = {}
	for Name, Item in Found.Work do
		local Mark = Book.AsMark(Item)
		if Mark and not Mark.Clean then
			table.insert(Marks, { Name = Name, Item = Mark, Ref = Context.Ref })
		end
	end
	return Marks
end

local function Look(Call: Call, Found: Result): string
	local Context = Call.Context
	Context.Found = Found
	return if type(Found) == "table" and Unclean(Context, Found)[1] then WORD.Unclean else Asks.SAID.Done
end

local function Landed(Call: Call): Result
	local Note = Machine.Reply(Call).Note
	if Note == nil then
		return Answer.Unresolved
	elseif Note.Stored then
		return View.Read(Note.Stored, Call.Context.Build)
	end
	return STOPS[Note.Why :: Types.Why] or Answer.Unresolved
end

local function Show(Call: Call): string
	local Context = Call.Context
	local Found = Context.Found
	if type(Found) == "table" then
		Context.Shown:Show(Context.Mark, Found.Writes)
	end
	Machine.Answer(Call, Found)
	return STATE.Done
end

local function Read(Call: Call)
	Machine.Ask(Call, Asks.Read(Call.Context.Ref))
end

local function Got(Call: Call): string
	local Context, Reply = Call.Context, Machine.Reply(Call)
	if Reply.Said == Asks.SAID.Failed then
		return Look(Call, Answer.Unresolved)
	end
	local Found = View.Read(Reply.Value, Context.Build)
	local Writes = if type(Found) == "string" then 0 else Found.Writes
	if not Context.Shown:Allows(Context.Mark, Writes) then
		return WORD.Stale
	end
	return Look(Call, Found)
end

local function Refresh(Call: Call)
	Machine.Ask(Call, Asks.Send(Call.Context.Ref, Requests.Fresh()))
end

local function Refreshed(Call: Call): string
	return Look(Call, Landed(Call))
end

local function Check(Call: Call)
	local Context = Call.Context
	Context.Checks = Unclean(Context, Context.Found :: View.View)
	table.clear(Context.Commits)
	for _, Found in Context.Checks do
		Machine.Ask(Call, Asks.Read(Found.Item.Decider))
	end
end

local function Checked(Call: Call): string
	local Context = Call.Context
	for Index, Reply in Call.Heard do
		local Found = Context.Checks[Index]
		if Reply.Said == Asks.SAID.Failed then
			Context.Found = Answer.Unresolved
			return Asks.SAID.Done
		end
		local Decided = Blockers.Read(Reply.Value, Found)
		if Decided and Decided.Outcome == Requests.Outcome.Commit then
			table.insert(Context.Commits, Blockers.End(Found, Decided.Outcome, Decided.Attempt, Decided.Value))
		end
	end
	return if Context.Commits[1] then WORD.Committed else Asks.SAID.Done
end

local function Resolve(Call: Call)
	local Context = Call.Context
	Machine.Ask(Call, Asks.Send(Context.Ref, Requests.Fresh(table.clone(Context.Commits))))
end

local function Resolved(Call: Call): string
	Call.Context.Found = Landed(Call)
	return Asks.SAID.Done
end

local STATES: { [string]: Machine.State<Context, Result> } = {
	[STATE.Reading] = {
		Enter = Read,
		Hear = Got,
		On = {
			{ Said = WORD.Stale, Go = STATE.Refreshing },
			{ Said = WORD.Unclean, Go = STATE.Checking },
		},
		Else = Show,
	},
	[STATE.Refreshing] = {
		Enter = Refresh,
		Hear = Refreshed,
		On = {
			{ Said = WORD.Unclean, Go = STATE.Checking },
		},
		Else = Show,
	},
	[STATE.Checking] = {
		Enter = Check,
		Hear = Checked,
		On = {
			{ Said = WORD.Committed, Go = STATE.Resolving },
		},
		Else = Show,
	},
	[STATE.Resolving] = {
		Enter = Resolve,
		Hear = Resolved,
		Else = Show,
	},
	[STATE.Done] = {},
}

function Peek.Context(Ref: Book.Ref, Build: Types.Build, Table: Shown.Shown): Context
	return {
		Ref = Ref,
		Mark = Book.Address(Ref),
		Build = Build,
		Shown = Table,
		Found = Answer.Unresolved,
		Checks = {},
		Commits = {},
	}
end

Peek.Cached = Machine.Define({ Name = "Peek", Initial = STATE.Reading, States = STATES })
Peek.Fresh = Machine.Define({ Name = "Peek", Initial = STATE.Refreshing, States = STATES })

return Peek
