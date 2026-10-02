--!strict
--!optimize 2

--[=[
	Cut: Machine. Runs one Reset or one Erase for the server that asked, or finishes another cut's
	gate as its helper.

	Spec: cuts 3.2 to 3.4.

	The cut is sent with every end the call has learned. A name kept answers true, and one under
	other terms Spent. Forgotten and Behind answer so when no request of the call may have written,
	and Unresolved when one may. Missing answers Missing when none may have written. When one may, it
	answers true for an Erase and Unresolved for a Reset. Marks, and the items an overdue key lists,
	are fenced at their deciders, not finally, and what each fence reports rides on the next send. A
	pinned record runs Touch. Another cut's gate is finished first, by this machine as its helper. A
	seal an erase left over is taken off by Unseal, and a seal another erase holds answers Busy. Each
	of these goes round at most Limits.TRIES times.

	An Erase that meets its seal answers true with it, and the machine runs on after it answers.
	When its own write made the seal, it sends the key's one RemoveAsync while the clock reads at
	most Windows.REMOVE_SEND past rt. Later than that, it stamps the seal again first. A helper waits
	the cut window first. Every sealer reads the key again once rt is Windows.SEAL_AGE old, and
	stamps and removes the same seal if it still stands.

	Return type: The Cut module, and the Context and Result types.
	Example usage:
		local Result = Runner.Run(Cut.Machine, Cut.Context(Ref, Asked, true), Places):Wait()
--]=]

local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Blockers = require("../Record/Blockers")
local Book = require("../Record/Book")
local Key = require("../Record/Key")
local Limits = require("../Core/Constants/Limits")
local Machine = require("../Machine/Machine")
local Queue = require("../Record/Queue")
local Requests = require("../Record/Requests")
local Touch = require("./Touch")
local Types = require("../Record/Types")
local Unseal = require("./Unseal")
local Windows = require("../Core/Constants/Windows")

export type Result = {
	read Reply: Queue.Reply,
	read Seal: Book.Seal?,
}

export type Context = {
	read Ref: Book.Ref,
	read Cut: Requests.Cut,
	read Erasable: boolean,
	Seen: (string | false)?,
	Ends: { Requests.End },
	Rounds: number,
	Checks: number,
	Wrote: boolean,
	Items: { [string]: Book.Work },
	Asked: { Blockers.Blocker | false },
	Gate: Book.Gate?,
	Wait: number?,
	Seal: Book.Seal?,
}

type Call = Machine.Call<Context, Result>

local STATE = {
	Learning = "Learning" :: "Learning",
	Cutting = "Cutting" :: "Cutting",
	Fencing = "Fencing" :: "Fencing",
	Helping = "Helping" :: "Helping",
	Waiting = "Waiting" :: "Waiting",
	Unsealing = "Unsealing" :: "Unsealing",
	Removing = "Removing" :: "Removing",
	Ripening = "Ripening" :: "Ripening",
	Checking = "Checking" :: "Checking",
	Rechecking = "Rechecking" :: "Rechecking",
	Restamping = "Restamping" :: "Restamping",
	Done = "Done" :: "Done",
}

local WORD = {
	Left = "Left" :: "Left",
	Busy = "Busy" :: "Busy",
	Standing = "Standing" :: "Standing",
	Due = "Due" :: "Due",
}

local WorkForm = Book.WorkForm
local Report = Types.Report
local Why = Types.Why
local SAID = Asks.SAID

local Cut = {}
local Self: Machine.Machine<Context, Result>

local function Answered(Reply: Queue.Reply): (Call: Call) -> string
	return function(Call: Call): string
		local Made: Result = { Reply = Reply }
		Machine.Answer(Call, Made)
		return STATE.Done
	end
end

local function Clean(Fallback: Queue.Reply): (Call: Call) -> string
	return function(Call: Call): string
		return Answered(if Call.Context.Wrote then Answer.Unresolved else Fallback)(Call)
	end
end

local function RoundsLeft(Call: Call): boolean
	return Call.Context.Rounds < Limits.TRIES
end

local function Ride(Context: Context, End: Requests.End)
	for Index, Riding in Context.Ends do
		if Riding.Name == End.Name then
			Context.Ends[Index] = End
			return
		end
	end
	table.insert(Context.Ends, End)
end

local function Learn(Call: Call)
	local Context = Call.Context
	if Context.Erasable and Context.Seen == nil then
		Machine.Ask(Call, Asks.Read(Context.Ref))
	end
end

local function Learned(Call: Call): string
	local Reply = Call.Heard[1]
	if Reply == nil then
		return SAID.Done
	elseif Reply.Said == SAID.Failed then
		return SAID.Failed
	end
	local Found = Key.Read(Reply.Value)
	Call.Context.Seen = if type(Found) == "table" then Found.Book.Id or "" elseif Found == nil or Found == Why.Missing then false else ""
	return SAID.Done
end

local function Send(Call: Call)
	local Context = Call.Context
	local Asked = table.clone(Context.Cut) :: any
	local Seen = Context.Seen
	Asked.Id = if Context.Erasable and Seen and Seen ~= "" then Seen else nil
	local Ends = if Context.Ends[1] then table.clone(Context.Ends) else nil
	Machine.Ask(Call, Asks.Send(Context.Ref, Requests.Cut(Asked, Ends)))
end

local function Heard(Call: Call): string
	local Context = Call.Context
	local Reply = Machine.Reply(Call)
	local Note = Reply.Note
	if Reply.Wrote or Note == nil then
		Context.Wrote = true
	end
	if Note == nil then
		return SAID.Failed
	end
	Context.Items = Note.Items or {}
	Context.Gate = Note.Gate
	Context.Wait = Note.Wait
	if Note.Seal then
		Context.Seal = Note.Seal
	end
	if Note.Report then
		return Note.Report
	elseif Note.Why == Why.Missing and Note.Seal then
		return if Note.Left then WORD.Left else WORD.Busy
	end
	return Note.Why or SAID.Done
end

local function Missing(Call: Call): string
	local Context = Call.Context
	if not Context.Wrote then
		return Answered(Answer.Missing)(Call)
	end
	return Answered(if Context.Cut.Kind == Book.Cause.Erase then true else Answer.Unresolved)(Call)
end

local function Sealed(Call: Call): string
	local Context = Call.Context
	local Seal = assert(Context.Seal, "Cut: sealed with no seal")
	local Made: Result = { Reply = true, Seal = Seal }
	Machine.Answer(Call, Made)
	local Note = Machine.Reply(Call).Note
	if Note == nil or Note.Stored == nil or Seal.Server ~= Context.Cut.Server then
		return STATE.Checking
	elseif Context.Cut.Helper then
		return STATE.Ripening
	elseif Call.Now - Seal.Rt <= Windows.REMOVE_SEND then
		return STATE.Removing
	end
	return STATE.Restamping
end

local function Fence(Call: Call)
	local Context = Call.Context
	table.clear(Context.Asked)
	for Name, Item in Context.Items do
		if Item.Form == WorkForm.Pinned then
			Context.Asked[#Context.Asked + 1] = false
			Machine.Ask(Call, Asks.Run(Touch.Pinned, Touch.Context(Name, Item, Context.Ref, Windows.SETTLE)))
		else
			local Found: Blockers.Blocker = { Name = Name, Item = Item, Ref = Context.Ref }
			table.insert(Context.Asked, Found)
			Machine.Ask(Call, Asks.Send(Item.Decider, Blockers.Fence(Found)))
		end
	end
end

local function Fenced(Call: Call): string
	local Context = Call.Context
	for Order, Reply in Call.Heard do
		local Found = Context.Asked[Order]
		local Decided = if Found then Blockers.Fenced(Reply.Note, Found) else nil
		if Found and Decided and Decided.Outcome then
			Ride(Context, Blockers.End(Found, Decided.Outcome, Decided.Attempt, Decided.Value))
		end
	end
	Context.Rounds += 1
	return SAID.Done
end

local function Help(Call: Call)
	local Context = Call.Context
	local Gate = assert(Context.Gate, "Cut: helping with no gate")
	local Mine = Context.Cut
	local Helper: Requests.Cut = { Name = Gate.Name, Stamp = Gate.Stamp, Kind = Gate.Kind, Print = Gate.Print, Helper = true, Server = Mine.Server }
	local Other = Cut.Context(Context.Ref, Helper, Context.Erasable)
	Other.Seen = Context.Seen
	Machine.Ask(Call, Asks.Run(Self, Other))
end

local function Again(Call: Call): string
	Call.Context.Rounds += 1
	return STATE.Cutting
end

local function Rest(Call: Call)
	local Context = Call.Context
	Machine.Ask(Call, Asks.Wait((Context.Wait or Context.Cut.Stamp) - Call.Now))
end

local function Clear(Call: Call)
	Machine.Ask(Call, Asks.Run(Unseal.Machine, Unseal.Context(Call.Context.Ref, Call.Context.Cut.Server, nil)))
end

local function Remove(Call: Call)
	Machine.Ask(Call, Asks.Remove(Call.Context.Ref))
end

local function Removed(Call: Call): string
	Call.Context.Checks += 1
	return if Call.Context.Checks < Limits.TRIES then STATE.Checking else STATE.Done
end

local function Ripen(Call: Call)
	local Seal = assert(Call.Context.Seal, "Cut: ripening with no seal")
	Machine.Ask(Call, Asks.Wait(Seal.Stamp + Windows.CUT - Call.Now))
end

local function Check(Call: Call)
	local Seal = assert(Call.Context.Seal, "Cut: checking with no seal")
	Machine.Ask(Call, Asks.Wait(Seal.Rt + Windows.SEAL_AGE - Call.Now))
end

local function Look(Call: Call)
	Machine.Ask(Call, Asks.Read(Call.Context.Ref))
end

local function Looked(Call: Call): string
	local Reply = Machine.Reply(Call)
	local Seal, Held = Call.Context.Seal, Key.Seal(Reply.Value)
	if Reply.Said == SAID.Failed or Seal == nil or Held == nil or Held.Rt ~= Seal.Rt or Held.Server ~= Seal.Server then
		return SAID.Done
	end
	return WORD.Standing
end

local function Restamp(Call: Call)
	local Context = Call.Context
	local Seal = assert(Context.Seal, "Cut: stamping with no seal")
	local Server = Context.Cut.Server
	local Step: Requests.Stamp = { Server = Server, Rt = if Seal.Server == Server then Seal.Rt else nil }
	Machine.Ask(Call, Asks.Send(Context.Ref, Requests.Stamp(Step)))
end

local function Restamped(Call: Call): string
	local Context = Call.Context
	local Note = Machine.Reply(Call).Note
	local Seal = if Note and Note.Report == Report.Stamped then Note.Seal else nil
	if Seal == nil or Seal.Server ~= Context.Cut.Server or Call.Now - Seal.Rt > Windows.REMOVE_SEND then
		return SAID.Done
	end
	Context.Seal = Seal
	return WORD.Due
end

local STATES: { [string]: Machine.State<Context, Result> } = {
	[STATE.Learning] = {
		Enter = Learn,
		Hear = Learned,
		On = {
			{ Said = SAID.Failed, Go = Answered(Answer.Unresolved) },
		},
		Else = STATE.Cutting,
	},
	[STATE.Cutting] = {
		Enter = Send,
		Hear = Heard,
		On = {
			{ Said = Report.Took, Go = Answered(true) },
			{ Said = Report.Sealed, Go = Sealed },
			{ Said = Report.Spent, Go = Answered(Answer.Spent) },
			{ Said = Report.Forgotten, Go = Clean(Answer.Expired) },
			{ Said = Report.Behind, Go = Clean(Answer.Behind) },
			{ Said = Why.Behind, Go = Clean(Answer.Behind) },
			{ Said = Report.Marks, When = RoundsLeft, Go = STATE.Fencing },
			{ Said = Why.Overdue, When = RoundsLeft, Go = STATE.Fencing },
			{ Said = Report.GatedBy, When = RoundsLeft, Go = STATE.Helping },
			{ Said = Report.Ahead, When = RoundsLeft, Go = STATE.Waiting },
			{ Said = Report.Wait, When = RoundsLeft, Go = STATE.Waiting },
			{ Said = WORD.Left, When = RoundsLeft, Go = STATE.Unsealing },
			{ Said = WORD.Busy, Go = Answered(Answer.Busy) },
			{ Said = Why.Missing, Go = Missing },
		},
		Else = Answered(Answer.Unresolved),
	},
	[STATE.Fencing] = {
		Enter = Fence,
		Hear = Fenced,
		Else = STATE.Cutting,
	},
	[STATE.Helping] = {
		Enter = Help,
		Else = Again,
	},
	[STATE.Waiting] = {
		Enter = Rest,
		Else = Again,
	},
	[STATE.Unsealing] = {
		Enter = Clear,
		Else = Again,
	},
	[STATE.Removing] = {
		Enter = Remove,
		Else = Removed,
	},
	[STATE.Ripening] = {
		Enter = Ripen,
		Else = STATE.Restamping,
	},
	[STATE.Checking] = {
		Enter = Check,
		Else = STATE.Rechecking,
	},
	[STATE.Rechecking] = {
		Enter = Look,
		Hear = Looked,
		On = {
			{ Said = WORD.Standing, Go = STATE.Restamping },
		},
		Else = STATE.Done,
	},
	[STATE.Restamping] = {
		Enter = Restamp,
		Hear = Restamped,
		On = {
			{ Said = WORD.Due, Go = STATE.Removing },
		},
		Else = STATE.Done,
	},
	[STATE.Done] = {},
}

function Cut.Context(Ref: Book.Ref, Asked: Requests.Cut, Erasable: boolean): Context
	return {
		Ref = Ref,
		Cut = Asked,
		Erasable = Erasable,
		Ends = {},
		Rounds = 0,
		Checks = 0,
		Wrote = false,
		Items = {},
		Asked = {},
	}
end

Self = Machine.Define({ Name = "Cut", Initial = STATE.Learning, States = STATES })
Cut.Machine = Self

return Cut
