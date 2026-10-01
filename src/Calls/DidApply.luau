--!strict
--!optimize 2

--[=[

	DidApply: Machine. Says whether a game's name took effect on a key.

	Spec: record 5.3. Model: Rec.tla, ReadHear for a didapply.

	Reading reads the key once: true when it holds the name as took or as a pinned use, else
	Unresolved. It is the only form for an untimed name, which never answers false. Probing sends a
	probe that decides nothing. A held name answers true when it took and false when not, and a
	pinned use answers true. A standing mark and a forgotten name answer Unresolved. A probe that
	lands answers false for the moment it landed. A key that holds no value, or one past this build,
	answers why.

	Return type: A table with Reading, Probing and Context. The type is Context.
	Example usage:
		local Said = Runner.Run(DidApply.Probing, DidApply.Context(Ref, Once, Stamp), Places):Wait()
--]=]

local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Book = require("../Record/Book")
local Key = require("../Record/Key")
local Machine = require("../Machine/Machine")
local Types = require("../Record/Types")

type Result = boolean | Answer.Answer

export type Context = {
	read Ref: Book.Ref,
	read Once: string,
	read Stamp: number?,
}

type Call = Machine.Call<Context, Result>

local STATE: {
	read Reading: "Reading",
	read Probing: "Probing",
	read Done: "Done",
} = {
	Reading = "Reading",
	Probing = "Probing",
	Done = "Done",
}

local WORD: {
	read Took: "Took",
	read Other: "Other",
	read Landed: "Landed",
} = {
	Took = "Took",
	Other = "Other",
	Landed = "Landed",
}

local Why = Types.Why

local DidApply = {}

local function Answered(Result: Result): (Call: Call) -> string
	return function(Call: Call): string
		Machine.Answer(Call, Result)
		return STATE.Done
	end
end

local function Read(Call: Call)
	Machine.Ask(Call, Asks.Read(Call.Context.Ref))
end

local function Held(Call: Call): string
	local Found = Key.Read(Machine.Reply(Call).Value)
	if type(Found) ~= "table" then
		return Asks.SAID.Done
	end
	local Name = Call.Context.Once
	local Working = Found.Book.Work[Name]
	local Item = Found.Book:Held(Name)
	if Working and Working.Form == "Pinned" then
		return WORD.Took
	end
	return if Working == nil and Item and Item.Fate == Book.Fate.Took then WORD.Took else Asks.SAID.Done
end

local function Probe(Call: Call)
	local Context = Call.Context
	local Stamp = assert(Context.Stamp, "DidApply: a probe needs a stamp")
	local Request: Types.Request = { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Probe = { Name = Context.Once, Stamp = Stamp } }
	Machine.Ask(Call, Asks.Send(Context.Ref, Request))
end

local function Probed(Call: Call): string
	local Note = Machine.Reply(Call).Note
	if Note == nil then
		return Asks.SAID.Failed
	elseif Note.Held then
		return if Note.Held == Book.Fate.Took then WORD.Took else WORD.Other
	elseif Note.Stored then
		return WORD.Landed
	end
	return Note.Why or Asks.SAID.Done
end

local STATES: { [string]: Machine.State<Context, Result> } = {
	[STATE.Reading] = {
		Enter = Read,
		Hear = Held,
		On = {
			{ Said = WORD.Took, Go = Answered(true) },
		},
		Else = Answered(Answer.Unresolved),
	},
	[STATE.Probing] = {
		Enter = Probe,
		Hear = Probed,
		On = {
			{ Said = WORD.Took, Go = Answered(true) },
			{ Said = WORD.Other, Go = Answered(false) },
			{ Said = WORD.Landed, Go = Answered(false) },
			{ Said = Why.Missing, Go = Answered(Answer.Missing) },
			{ Said = Why.Behind, Go = Answered(Answer.Behind) },
			{ Said = Why.Worn, Go = Answered(Answer.Worn) },
		},
		Else = Answered(Answer.Unresolved),
	},
	[STATE.Done] = {},
}

function DidApply.Context(Ref: Book.Ref, Once: string, Stamp: number?): Context
	return { Ref = Ref, Once = Once, Stamp = Stamp }
end

DidApply.Reading = Machine.Define({ Name = "DidApply", Initial = STATE.Reading, States = STATES })
DidApply.Probing = Machine.Define({ Name = "DidApply", Initial = STATE.Probing, States = STATES })

return DidApply
