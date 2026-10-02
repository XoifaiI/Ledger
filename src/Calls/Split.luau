--!strict
--!optimize 2

--[=[
	Split: Machine. Opens a split quantity's parts, and closes and removes them.

	Spec: hot keys 2.1 and 2.5. Model: Hot.tla, SendOp and Hear for open and close.

	Open commits the open op on every part at once, under the quantity's open name and one stamp,
	with the declaration's print. A part that did not answer true is tried again after a rest, but
	only while the clock reads at most Windows.REMOVE_SEND past the stamp. Past it, Open answers
	Unresolved. It answers true once every part answered true.

	Close commits the close op on every part at once, then reads every part that closed. A part is
	removed with one RemoveAsync only when its state is empty, its work room holds nothing, and the
	clock reads Windows.SEAL_AGE past the stamp it was opened at. A part that reads gone counts as
	removed. Close answers true with how many parts are removed and how many are left.

	Return type: The Split module, with the machines Open and Close, and the Context and Closed
	types.
	Example usage:
		local Done = Runner.Run(Split.Open, Split.Context(Declared, Name, Stamp, Server), Places):Wait()
--]=]

local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Backoff = require("../Machine/Backoff")
local Book = require("../Record/Book")
local Key = require("../Record/Key")
local Machine = require("../Machine/Machine")
local Parts = require("../Record/Parts")
local Queue = require("../Record/Queue")
local Tx = require("./Tx")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")

export type Closed = {
	read Reply: Queue.Reply,
	read Removed: number,
	read Left: number,
}

export type Context = {
	read Declared: Parts.Declared,
	read Name: string,
	read Stamp: number,
	read Server: number,
	Pending: { number },
	Running: { Tx.Context },
	Closed: { number },
	Removing: { number },
	Removed: number,
	Rounds: number,
}

type Said = Queue.Reply | Closed
type Call = Machine.Call<Context, Said>

local STATE = {
	Opening = "Opening" :: "Opening",
	Resting = "Resting" :: "Resting",
	Closing = "Closing" :: "Closing",
	Reading = "Reading" :: "Reading",
	Removing = "Removing" :: "Removing",
	Done = "Done" :: "Done",
}

local WORD = {
	Opened = "Opened" :: "Opened",
	Late = "Late" :: "Late",
	Read = "Read" :: "Read",
	Remove = "Remove" :: "Remove",
}

local Split = {}

local function Give(Call: Call, Result: Said)
	Machine.Answer(Call, Result)
end

local function Ref(Declared: Parts.Declared, Index: number): Book.Ref
	return { Store = Declared.Place, Key = Parts.Key(Declared.Name, Declared.Parts, Index) }
end

local function Send(Call: Call, Index: number, Body: { [string]: any }, MustExist: boolean)
	local Context = Call.Context
	local Leg: Tx.Leg = { Ref = Ref(Context.Declared, Index), MustExist = MustExist, Erasable = false, Change = { Body = Body } }
	local Use: Tx.Use = { Name = Context.Name, Stamp = Context.Stamp, Print = Context.Declared.Print }
	local Running = Tx.Context(Use, { Leg }, 1, Context.Server)
	table.insert(Context.Running, Running)
	Machine.Ask(Call, Asks.Run(Tx.Retry, Running))
end

local function Open(Call: Call)
	local Context = Call.Context
	local Declared = Context.Declared
	table.clear(Context.Running)
	for _, Index in Context.Pending do
		local Share = Parts.Share(Declared.Stock, Declared.Parts, Index)
		Send(Call, Index, { Kind = "Open", Share = Share, At = Context.Stamp, From = Parts.From(Declared, Index) }, false)
	end
end

local function Opened(Call: Call): string
	local Context = Call.Context
	local Left: { number } = {}
	for Order, Reply in Call.Heard do
		if Reply.Answer ~= true then
			table.insert(Left, Context.Pending[Order])
		end
	end
	Context.Pending = Left
	if Left[1] == nil then
		Give(Call, true)
		return WORD.Opened
	elseif Call.Now - Context.Stamp > Windows.REMOVE_SEND then
		Give(Call, Answer.Unresolved)
		return WORD.Late
	end
	return Asks.SAID.Done
end

local function Rest(Call: Call)
	local Context = Call.Context
	Context.Rounds += 1
	Machine.Ask(Call, Asks.Wait(Backoff.Retry(Context.Rounds)))
end

local function Close(Call: Call)
	local Context = Call.Context
	table.clear(Context.Running)
	for Index = 0, Context.Declared.Parts - 1 do
		Send(Call, Index, { Kind = "Close", Print = Context.Declared.Print }, true)
	end
end

local function Shut(Call: Call): string
	local Context = Call.Context
	for Order, Reply in Call.Heard do
		local Verdict = Context.Running[Order].Verdict
		if Reply.Answer == true then
			table.insert(Context.Closed, Order - 1)
		elseif Verdict and Verdict.Why == Types.Why.Missing then
			Context.Removed += 1
		end
	end
	return if Context.Closed[1] then WORD.Read else Asks.SAID.Done
end

local function Look(Call: Call)
	local Context = Call.Context
	for _, Index in Context.Closed do
		Machine.Ask(Call, Asks.Read(Ref(Context.Declared, Index)))
	end
end

local function Looked(Call: Call): string
	local Context = Call.Context
	for Order, Reply in Call.Heard do
		local Found = if Reply.Said == Asks.SAID.Failed then nil else Key.Read(Reply.Value)
		local Part = Parts.Read(Reply.Value)
		if Reply.Said ~= Asks.SAID.Failed and Found == nil then
			Context.Removed += 1
		elseif type(Found) == "table" and Part and next(Found.Book.Work) == nil and Parts.Empty(Part, Context.Declared) then
			if Call.Now - Part.Opened >= Windows.SEAL_AGE then
				table.insert(Context.Removing, Context.Closed[Order])
			end
		end
	end
	return if Context.Removing[1] then WORD.Remove else Asks.SAID.Done
end

local function Remove(Call: Call)
	local Context = Call.Context
	for _, Index in Context.Removing do
		Machine.Ask(Call, Asks.Remove(Ref(Context.Declared, Index)))
	end
end

local function Removed(Call: Call): string
	local Context = Call.Context
	for _, Reply in Call.Heard do
		if Reply.Said ~= Asks.SAID.Failed then
			Context.Removed += 1
		end
	end
	return Asks.SAID.Done
end

local function Report(Call: Call): string
	local Context = Call.Context
	local Made: Closed = { Reply = true, Removed = Context.Removed, Left = Context.Declared.Parts - Context.Removed }
	Give(Call, Made)
	return STATE.Done
end

local STATES: { [string]: Machine.State<Context, Said> } = {
	[STATE.Opening] = {
		Enter = Open,
		Hear = Opened,
		On = {
			{ Said = WORD.Opened, Go = STATE.Done },
			{ Said = WORD.Late, Go = STATE.Done },
		},
		Else = STATE.Resting,
	},
	[STATE.Resting] = {
		Enter = Rest,
		Else = STATE.Opening,
	},
	[STATE.Closing] = {
		Enter = Close,
		Hear = Shut,
		On = {
			{ Said = WORD.Read, Go = STATE.Reading },
		},
		Else = Report,
	},
	[STATE.Reading] = {
		Enter = Look,
		Hear = Looked,
		On = {
			{ Said = WORD.Remove, Go = STATE.Removing },
		},
		Else = Report,
	},
	[STATE.Removing] = {
		Enter = Remove,
		Hear = Removed,
		Else = Report,
	},
	[STATE.Done] = {},
}

function Split.Context(Declared: Parts.Declared, Name: string, Stamp: number, Server: number): Context
	local Pending: { number } = {}
	for Index = 0, Declared.Parts - 1 do
		table.insert(Pending, Index)
	end
	return {
		Declared = Declared,
		Name = Name,
		Stamp = Stamp,
		Server = Server,
		Pending = Pending,
		Running = {},
		Closed = {},
		Removing = {},
		Removed = 0,
		Rounds = 0,
	}
end

Split.Open = Machine.Define({ Name = "Open", Initial = STATE.Opening, States = STATES })
Split.Close = Machine.Define({ Name = "Close", Initial = STATE.Closing, States = STATES })

return Split
