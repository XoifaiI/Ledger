--!strict
--!optimize 2

--[=[
	Walk: Machine. Takes or holds units of a split quantity on at most one of its parts.

	Under a game name the order of the parts is the name's hash and then each next part, the same on
	every server. Each step sends under a sub name, the name and the part's alphabet character. Under
	drawn names the server's home part goes first, then the parts its view shows with the most free
	units, at most Parts.PROBES in all, and each step takes a fresh drawn name. The view is the
	quantity's, shared by its walks. It keeps the count a part last refused, and for Parts.VIEW_AGE
	the part is dry for a walk that asks at least that many units; a walk that asks fewer tries it. A
	part seen sealed or closed is dry for ever. A drawn walk leaves a dry part out. A game name never
	answers from memory: it sends a dry part a final fence in place of a try.

	A try is one transaction whose decider is the part, with the game's legs. The walk goes on to the
	next part only on a definite no: the part's own refusal, or a fence that reported fenced. The
	reason for a refusal is the part's own decision, run again on the state the refusing write left.
	A commit answers true with the part, the decider value and the part's state. Any other answer
	stops the walk with it. After the last part, the walk answers SoldOut when every part is known
	sealed or closed, and Short with the last part's reason otherwise. A drawn walk that tried
	nothing answers Busy, or SoldOut when every part is known.

	Return type: The Walk module, and the Asked, Context, View and Result types.
	Example usage:
		local Result = Runner.Run(Walk.Machine, Walk.Context(Asked), Places):Wait()
--]=]

local Alphabet = require("../Encode/Alphabet")
local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Book = require("../Record/Book")
local Hash = require("../Encode/Hash")
local Machine = require("../Machine/Machine")
local Parts = require("../Record/Parts")
local Queue = require("../Record/Queue")
local Requests = require("../Record/Requests")
local Tx = require("./Tx")
local Types = require("../Record/Types")

export type View = {
	read Free: number,
	read Shut: boolean,
	read Refused: number?,
	read At: number,
}

export type Result = {
	read Reply: Queue.Reply,
	read Part: number?,
	read Reason: Parts.Reason?,
	read Value: number?,
	read State: unknown,
}

export type Asked = {
	read Declared: Parts.Declared,
	read Body: Parts.Op,
	read Legs: { Tx.Leg },
	read Server: number,
	read Home: number,
	read Only: number?,
	read Name: string?,
	read Stamp: number,
	read Print: number?,
	read Names: { string },
	read View: { [number]: View },
}

export type Context = {
	read Asked: Asked,
	Order: { number },
	Step: number,
	Known: { [number]: true },
	Reason: Parts.Reason?,
	Fencing: boolean,
	Tx: Tx.Context?,
}

type Call = Machine.Call<Context, Result>

local STATE = {
	Choosing = "Choosing" :: "Choosing",
	Trying = "Trying" :: "Trying",
	Ending = "Ending" :: "Ending",
	Done = "Done" :: "Done",
}

local WORD = {
	Next = "Next" :: "Next",
	Stop = "Stop" :: "Stop",
}

local Report = Types.Report
local Why = Types.Why

local Walk = {}

local function Ref(Declared: Parts.Declared, Index: number): Book.Ref
	return { Store = Declared.Place, Key = Parts.Key(Declared.Name, Declared.Parts, Index) }
end

local function SeenFree(View: { [number]: View }, Index: number): number
	local Seen = View[Index]
	if Seen == nil then
		return 0
	end
	return Seen.Free
end

local function Dry(Context: Context, Index: number, Now: number): boolean
	local Asked = Context.Asked
	local Seen = Asked.View[Index]
	if Context.Known[Index] then
		return true
	elseif Seen == nil then
		return false
	elseif Seen.Shut then
		return true
	elseif Seen.Refused == nil or Now - Seen.At > Parts.VIEW_AGE then
		return false
	end
	return Parts.Units(Asked.Body) >= Seen.Refused
end

local function GameOrder(Name: string, Count: number): { number }
	local First = Hash(Name) % Count
	local Order: { number } = {}
	for Offset = 0, Count - 1 do
		table.insert(Order, (First + Offset) % Count)
	end
	return Order
end

local function DrawnOrder(Context: Context, Now: number): { number }
	local Asked = Context.Asked
	local Others: { number } = {}
	for Index = 0, Asked.Declared.Parts - 1 do
		if Index ~= Asked.Home and not Dry(Context, Index, Now) then
			table.insert(Others, Index)
		end
	end
	table.sort(Others, function(Left: number, Right: number): boolean
		return SeenFree(Asked.View, Left) > SeenFree(Asked.View, Right)
	end)
	local Order: { number } = {}
	if not Dry(Context, Asked.Home, Now) then
		table.insert(Order, Asked.Home)
	end
	for _, Index in Others do
		if #Order == Parts.PROBES then
			break
		end
		table.insert(Order, Index)
	end
	return Order
end

local function KnownShut(Context: Context, Index: number): boolean
	if Context.Known[Index] then
		return true
	elseif Context.Asked.Name ~= nil then
		return false
	end
	local Seen = Context.Asked.View[Index]
	return Seen ~= nil and Seen.Shut
end

local function EveryPartShut(Context: Context): boolean
	for Index = 0, Context.Asked.Declared.Parts - 1 do
		if not KnownShut(Context, Index) then
			return false
		end
	end
	return true
end

local function Learn(Context: Context, Index: number, Note: Types.Note, Now: number)
	local Asked = Context.Asked
	local Part = Parts.Opened(Asked.Declared, Note.State)
	local Shut = Part ~= nil and Parts.IsShut(Part)
	local Free = if Part then Part.Free else 0
	Context.Reason = Parts.Refusal(Asked.Declared, Note.State, Asked.Body)
	Context.Known[Index] = if Shut then true else nil
	Asked.View[Index] = { Free = Free, Shut = Shut, Refused = Parts.Units(Asked.Body), At = Now }
end

local function Took(Call: Call, Value: number?, State: unknown): string
	local Context = Call.Context
	local Committed: Result = { Reply = true, Part = Context.Order[Context.Step], Value = Value, State = State }
	Machine.Answer(Call, Committed)
	return WORD.Stop
end

local function Stop(Call: Call, Reply: Queue.Reply): string
	Machine.Answer(Call, { Reply = Reply })
	return WORD.Stop
end

local function Fenced(Call: Call): string
	local Note = Machine.Reply(Call).Note
	if Note == nil then
		return Stop(Call, Answer.Unresolved)
	elseif Note.Report == Report.Committed then
		return Took(Call, Note.Value, Note.State)
	elseif Note.Report == Report.Fenced or Note.Report == Report.Refused then
		return WORD.Next
	elseif Note.Why == Why.Missing then
		return Stop(Call, Answer.Missing)
	elseif Note.Report == Report.Forgotten then
		return Stop(Call, Answer.Expired)
	end
	return Stop(Call, Answer.Unresolved)
end

local function Ran(Call: Call): string
	local Context = Call.Context
	local Said = Machine.Reply(Call).Answer :: Queue.Reply?
	local Running = Context.Tx :: Tx.Context
	local Verdict = Running.Verdict
	if Said == true then
		return Took(Call, Running.Value, if Verdict then Verdict.State else nil)
	elseif Verdict and Verdict.Report == Report.Refused then
		Learn(Context, Context.Order[Context.Step], Verdict, Call.Now)
		return WORD.Next
	elseif Verdict and Verdict.Why == Why.Missing then
		return Stop(Call, Answer.Missing)
	elseif Said == nil then
		return Stop(Call, Answer.Unresolved)
	end
	return Stop(Call, Said)
end

local function Ending(Context: Context): Queue.Reply
	if EveryPartShut(Context) then
		return Answer.SoldOut
	elseif Context.Order[1] ~= nil then
		return Answer.Short
	end
	return Answer.Busy
end

local function StepName(Context: Context, Index: number): string
	local Game = Context.Asked.Name
	if Game then
		return Walk.Sub(Game, Index)
	end
	return Context.Asked.Names[Context.Step]
end

local function Choose(Call: Call): string
	local Context = Call.Context
	local Asked = Context.Asked
	local Only, Name = Asked.Only, Asked.Name
	if Only then
		Context.Order = { Only }
	elseif Name then
		Context.Order = GameOrder(Name, Asked.Declared.Parts)
	else
		Context.Order = DrawnOrder(Context, Call.Now)
	end
	Context.Step = 1
	if Context.Order[1] == nil then
		return WORD.Stop
	end
	return Asks.SAID.Done
end

local function Try(Call: Call)
	local Context = Call.Context
	local Asked = Context.Asked
	local Index = Context.Order[Context.Step]
	local Part = Ref(Asked.Declared, Index)
	local Name = StepName(Context, Index)
	Context.Fencing = Asked.Name ~= nil and Dry(Context, Index, Call.Now)
	if Context.Fencing then
		local Fence: Requests.Fence = { Name = Name, Stamp = Asked.Stamp, Attempt = 1, Print = Asked.Print, Final = true }
		Machine.Ask(Call, Asks.Send(Part, Requests.Fence(Fence)))
		return
	end
	local Legs = table.clone(Asked.Legs)
	table.insert(Legs, { Ref = Part, MustExist = true, Erasable = false, Change = { Body = Asked.Body } })
	local Use: Tx.Use = { Name = Name, Stamp = Asked.Stamp, Print = if Asked.Name then Asked.Print else nil }
	local Running = Tx.Context(Use, Legs, #Legs, Asked.Server)
	Context.Tx = Running
	Machine.Ask(Call, Asks.Run(if Asked.Name then Tx.Retry else Tx.Run, Running))
end

local function Tried(Call: Call): string
	if Call.Context.Fencing then
		return Fenced(Call)
	end
	return Ran(Call)
end

local function Next(Call: Call): string
	local Context = Call.Context
	Context.Step += 1
	if Context.Order[Context.Step] then
		return STATE.Trying
	end
	return STATE.Ending
end

local function Conclude(Call: Call): string
	local Context = Call.Context
	Machine.Answer(Call, { Reply = Ending(Context), Reason = Context.Reason })
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
		Hear = Conclude,
		Else = STATE.Done,
	},
	[STATE.Done] = {},
}

function Walk.Sub(Name: string, Index: number): string
	return `{Name}_{string.char(buffer.readu8(Alphabet.CHARS, Index))}`
end

function Walk.Context(Asked: Asked): Context
	return {
		Asked = Asked,
		Order = {},
		Step = 1,
		Known = {},
		Fencing = false,
	}
end

Walk.Machine = Machine.Define({ Name = "Walk", Initial = STATE.Choosing, States = STATES })

return Walk
