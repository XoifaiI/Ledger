--!strict
--!optimize 2

--[=[

	Walk: Machine. Takes or holds units of a split quantity on at most one of its parts.

	Spec: hot keys 2.4 and 2.5. Model: Hot.tla, SendOp and Hear.

	Choosing orders the parts. Under a game name the order is the name's hash and then each next part,
	the same on every server. Each step sends under a sub name, the name and the part's alphabet
	character. Under drawn names the server's home part goes first, then the parts its view shows
	with the most free units. A part the view shows sealed, closed or short is left out, and at most
	Limits.PROBES parts are tried. Each step takes a fresh drawn name. A call given Only tries that
	one part. The view trusts a part it saw short for Windows.VIEW_AGE, and one it saw sealed or
	closed for ever. Each refusal a step hears goes into the view.

	Trying runs one transaction whose decider is the part, with the game's legs. Under a game name,
	a part the view shows sealed, closed or short gets a final fence in place of a try. A step goes
	on to the next part only on a definite no. That is the part's own refusal, or a fence that
	reported fenced. A commit answers true with the part. Missing answers Missing, and every other
	answer stops the walk with it. Under drawn names a part the view shows sealed or closed counts
	as known. A walk that tried nothing then answers SoldOut from memory when every part is known. A
	drawn walk that tried nothing otherwise answers Busy. A game name never answers from memory. A
	commit's result carries the decider value and the part's state, when it heard them. After the
	last part, the walk answers SoldOut when every part is known sealed or closed, and Short with
	the last part's reason otherwise. Known keeps each part this walk heard sealed or closed.

	Return type: A table with Machine, Context and Sub. The types are Context, View and Result.
	Example usage:
		local Result = Runner.Run(Walk.Machine, Walk.Context(Declared, Body, Legs, Server), Places):Wait()
--]=]

local Alphabet = require("../Encode/Alphabet")
local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Book = require("../Record/Book")
local Hash = require("../Encode/Hash")
local Limits = require("../Core/Constants/Limits")
local Machine = require("../Machine/Machine")
local Parts = require("../Record/Parts")
local Queue = require("../Record/Queue")
local Tx = require("./Tx")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")

export type View = {
	read Free: number,
	read Shut: boolean,
	read Short: boolean,
	read At: number,
}

export type Result = {
	read Reply: Queue.Reply,
	read Part: number?,
	read Reason: Parts.Reason?,
	read Value: number?,
	read State: unknown,
}

export type Context = {
	read Declared: Parts.Declared,
	read Body: { [string]: any },
	read Legs: { Tx.Leg },
	read Server: number,
	read Home: number,
	Only: number?,
	Name: string?,
	Stamp: number,
	Print: number?,
	Names: { string },
	View: { [number]: View },
	Order: { number },
	Step: number,
	Known: { [number]: true },
	Reason: Parts.Reason?,
	Fencing: boolean,
	Tx: Tx.Context?,
}

type Call = Machine.Call<Context, Result>

local STATE: {
	read Choosing: "Choosing",
	read Trying: "Trying",
	read Ending: "Ending",
	read Done: "Done",
} = {
	Choosing = "Choosing",
	Trying = "Trying",
	Ending = "Ending",
	Done = "Done",
}

local WORD: {
	read Next: "Next",
	read Stop: "Stop",
} = {
	Next = "Next",
	Stop = "Stop",
}

local Report = Types.Report
local Why = Types.Why

local Walk = {}

function Walk.Sub(Name: string, Index: number): string
	return `{Name}_{string.char(buffer.readu8(Alphabet.CHARS, Index))}`
end

local function Ref(Declared: Parts.Declared, Index: number): Book.Ref
	return { Store = Declared.Place, Key = Parts.Key(Declared.Name, Declared.Parts, Index) }
end

local function Dry(Context: Context, Index: number, Now: number): boolean
	local Seen = Context.View[Index]
	if Context.Known[Index] or (Seen and Seen.Shut) then
		return true
	end
	return Seen ~= nil and Seen.Short and Now - Seen.At <= Windows.VIEW_AGE
end

local function Choose(Call: Call): string
	local Context = Call.Context
	local Count = Context.Declared.Parts
	local Order: { number } = {}
	local Name, Only = Context.Name, Context.Only
	if Only then
		table.insert(Order, Only)
	elseif Name then
		local First = Hash(Name) % Count
		for Offset = 0, Count - 1 do
			table.insert(Order, (First + Offset) % Count)
		end
	else
		local Others: { number } = {}
		for Index = 0, Count - 1 do
			if Index ~= Context.Home and not Dry(Context, Index, Call.Now) then
				table.insert(Others, Index)
			end
		end
		table.sort(Others, function(Left: number, Right: number): boolean
			local Has, Other = Context.View[Left], Context.View[Right]
			return (if Has then Has.Free else 0) > (if Other then Other.Free else 0)
		end)
		if not Dry(Context, Context.Home, Call.Now) then
			table.insert(Order, Context.Home)
		end
		for _, Index in Others do
			if #Order < Limits.PROBES then
				table.insert(Order, Index)
			end
		end
	end
	Context.Order, Context.Step = Order, 1
	return if Order[1] then Asks.SAID.Done else WORD.Stop
end

local function Try(Call: Call)
	local Context = Call.Context
	local Index = Context.Order[Context.Step]
	local Part = Ref(Context.Declared, Index)
	local Game = Context.Name
	local Name = if Game then Walk.Sub(Game, Index) else Context.Names[Context.Step]
	Context.Fencing = Game ~= nil and Dry(Context, Index, Call.Now)
	if Context.Fencing then
		local Fence: Types.Fence = { Name = Name, Stamp = Context.Stamp, Attempt = 1, Print = Context.Print, Final = true }
		Machine.Ask(Call, Asks.Send(Part, { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Fence = Fence }))
		return
	end
	local Legs = table.clone(Context.Legs)
	table.insert(Legs, { Ref = Part, MustExist = true, Erasable = false, Change = { Body = Context.Body } })
	local Use: Tx.Use = { Name = Name, Stamp = Context.Stamp, Print = if Game then Context.Print else nil }
	local Running = Tx.Context(Use, Legs, #Legs, Context.Server)
	Context.Tx = Running
	Machine.Ask(Call, Asks.Run(if Game then Tx.Retry else Tx.Run, Running))
end

local function Learn(Context: Context, Index: number, Note: Types.Note, Now: number)
	local Reason = Parts.Reason(Note.State, Context.Body.Kind, Context.Body.Count or 0, Context.Body.Print)
	local Shut = Reason == "Sealed" or Reason == "Closed"
	local Part = Note.State :: Parts.Part
	Context.Reason = Reason
	Context.Known[Index] = if Shut then true else nil
	Context.View[Index] = { Free = if type(Part) == "table" then Part.Free or 0 else 0, Shut = Shut, Short = true, At = Now }
end

local function Stop(Call: Call, Reply: Queue.Reply, Note: Types.Note?): string
	local Context = Call.Context
	local Running = Context.Tx
	local Took = Reply == true
	local Value = if Note and Note.Value then Note.Value elseif Running then Running.Value else nil
	local Verdict = Note or (if Running then Running.Verdict else nil)
	Machine.Answer(Call, {
		Reply = Reply,
		Part = if Took then Context.Order[Context.Step] else nil,
		Value = if Took then Value else nil,
		State = if Took and Verdict then Verdict.State else nil,
	})
	return WORD.Stop
end

local function Fenced(Call: Call): string
	local Reply = Machine.Reply(Call)
	local Note = Reply.Note
	if Note == nil then
		return Stop(Call, Answer.Unresolved)
	elseif Note.Report == Report.Committed then
		return Stop(Call, true, Note)
	elseif Note.Report == Report.Fenced or Note.Report == Report.Refused then
		return WORD.Next
	elseif Note.Why == Why.Missing then
		return Stop(Call, Answer.Missing)
	elseif Note.Report == Report.Forgotten then
		return Stop(Call, Answer.Expired)
	end
	return Stop(Call, Answer.Unresolved)
end

local function Tried(Call: Call): string
	local Context = Call.Context
	if Context.Fencing then
		Context.Tx = nil
		return Fenced(Call)
	end
	local Said = Machine.Reply(Call).Answer :: Queue.Reply?
	local Verdict = (Context.Tx :: Tx.Context).Verdict
	if Said == true then
		return Stop(Call, true)
	elseif Verdict and Verdict.Report == Report.Refused then
		Learn(Context, Context.Order[Context.Step], Verdict, Call.Now)
		return WORD.Next
	elseif Verdict and Verdict.Why == Why.Missing then
		return Stop(Call, Answer.Missing)
	end
	return Stop(Call, Said or Answer.Unresolved)
end

local function Next(Call: Call): string
	local Context = Call.Context
	Context.Step += 1
	return if Context.Order[Context.Step] then STATE.Trying else STATE.Ending
end

local function Close(Call: Call): string
	local Context = Call.Context
	local Drawn = Context.Name == nil
	local Every = true
	for Index = 0, Context.Declared.Parts - 1 do
		local Seen = Context.View[Index]
		Every = Every and (Context.Known[Index] ~= nil or (Drawn and Seen ~= nil and Seen.Shut))
	end
	local Tried = Context.Order[1] ~= nil
	local Reply = if Every then Answer.SoldOut elseif Tried then Answer.Short else Answer.Busy
	Machine.Answer(Call, { Reply = Reply, Reason = Context.Reason })
	return Asks.SAID.Done
end

local STATES: { [string]: Machine.State<Context, Result> } = {
	[STATE.Choosing] = {
		Hear = Choose,
		On = {
			{ Said = WORD.Stop, Go = STATE.Ending },
		},
		Else = STATE.Trying,
	},
	[STATE.Trying] = {
		Enter = Try,
		Hear = Tried,
		On = {
			{ Said = WORD.Next, Go = Next },
		},
		Else = STATE.Done,
	},
	[STATE.Ending] = {
		Hear = Close,
		Else = STATE.Done,
	},
	[STATE.Done] = {},
}

function Walk.Context(Declared: Parts.Declared, Body: { [string]: any }, Legs: { Tx.Leg }, Server: number, Home: number): Context
	return {
		Declared = Declared,
		Body = Body,
		Legs = Legs,
		Server = Server,
		Home = Home,
		Stamp = 0,
		Names = {},
		View = {},
		Order = {},
		Step = 1,
		Known = {},
		Fencing = false,
	}
end

Walk.Machine = Machine.Define({ Name = "Walk", Initial = STATE.Choosing, States = STATES })

return Walk
