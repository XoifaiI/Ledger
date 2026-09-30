--!strict
--!optimize 2

--[=[

	Resettle: Machine. Ends every item on a key now, as a touch would, and says whether it is clear.

	Spec: transaction 5.3.

	Reading runs a fresh Peek of the key. Ending runs Touch on every item of its work room at once,
	with no level wait, and fences an undecided mark once it is Windows.SETTLE old. Checking runs a
	fresh Peek again. No item stamped before the call started answers true, and any other answers
	Busy. A peek that answers why answers that.

	Return type: A table with Machine and Context. The type is Context.
	Example usage:
		local Said = Runner.Run(Resettle.Machine, Resettle.Context(Ref, Build, Shown, Now), Places):Wait()
--]=]

local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Book = require("../Record/Book")
local Machine = require("../Machine/Machine")
local Peek = require("./Peek")
local Queue = require("../Record/Queue")
local Shown = require("../Record/Shown")
local Touch = require("./Touch")
local Touches = require("../Record/Touches")
local Types = require("../Record/Types")
local View = require("../Record/View")
local Windows = require("../Core/Constants/Windows")

type Reply = Queue.Reply

export type Context = {
	read Ref: Book.Ref,
	read Build: Types.Build,
	read Shown: Shown.Shown,
	read Start: number,
	Work: { [string]: Book.Work },
	Why: Answer.Answer,
}

type Call = Machine.Call<Context, Reply>

local STATE: {
	read Reading: "Reading",
	read Ending: "Ending",
	read Checking: "Checking",
	read Done: "Done",
} = {
	Reading = "Reading",
	Ending = "Ending",
	Checking = "Checking",
	Done = "Done",
}

local WORD: {
	read Viewed: "Viewed",
	read Clear: "Clear",
	read Busy: "Busy",
} = {
	Viewed = "Viewed",
	Clear = "Clear",
	Busy = "Busy",
}

local Resettle = {}

local function Answered(Result: Reply?): (Call: Call) -> string
	return function(Call: Call): string
		Machine.Answer(Call, Result or Call.Context.Why)
		return STATE.Done
	end
end

local function Look(Call: Call)
	local Context = Call.Context
	Machine.Ask(Call, Asks.Run(Peek.Fresh, Peek.Context(Context.Ref, Context.Build, Context.Shown)))
end

local function Viewed(Call: Call): View.View?
	local Found = Machine.Reply(Call).Answer
	if type(Found) == "table" then
		return Found :: View.View
	end
	Call.Context.Why = if type(Found) == "string" then Found :: Answer.Answer else Answer.Unresolved
	return nil
end

local function Read(Call: Call): string
	local Found = Viewed(Call)
	if Found == nil then
		return Asks.SAID.Done
	end
	Call.Context.Work = Found.Work
	return WORD.Viewed
end

local function End(Call: Call)
	local Context = Call.Context
	for Name, Item in Context.Work do
		local Start = if Item.Form == "Pinned" then Touch.Pinned else Touch.Mark
		Machine.Ask(Call, Asks.Run(Start, Touch.Context(Name, Item, Context.Ref, Windows.SETTLE)))
	end
end

local function Check(Call: Call): string
	local Found = Viewed(Call)
	if Found == nil then
		return Asks.SAID.Done
	end
	return if Touches.Clear(Found.Work, Call.Context.Start) then WORD.Clear else WORD.Busy
end

local STATES: { [string]: Machine.State<Context, Reply> } = {
	[STATE.Reading] = {
		Enter = Look,
		Hear = Read,
		On = {
			{ Said = WORD.Viewed, Go = STATE.Ending },
		},
		Else = Answered(),
	},
	[STATE.Ending] = {
		Enter = End,
		Else = STATE.Checking,
	},
	[STATE.Checking] = {
		Enter = Look,
		Hear = Check,
		On = {
			{ Said = WORD.Clear, Go = Answered(true) },
			{ Said = WORD.Busy, Go = Answered(Answer.Busy) },
		},
		Else = Answered(),
	},
	[STATE.Done] = {},
}

function Resettle.Context(Ref: Book.Ref, Build: Types.Build, Table: Shown.Shown, Start: number): Context
	return { Ref = Ref, Build = Build, Shown = Table, Start = Start, Work = {}, Why = Answer.Unresolved }
end

Resettle.Machine = Machine.Define({ Name = "Resettle", Initial = STATE.Reading, States = STATES })

return Resettle
