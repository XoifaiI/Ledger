--!strict
--!optimize 2

--[=[

	Total: Machine. Answers a total, and keeps its summary item while this server holds it.

	Spec: extras 2.4, 2.5 and 4. Model: Tot.tla, the reads rd[s] and Answer.

	Checking answers the sum of this server's pairs when every shard has one and its last full view
	is within MaxAge. Fetching gets the summary item and merges its pairs by write count. When every
	shard then has a pair it answers the sum and notes its full view. An item of a newer format
	answers Behind, and an item that lacks a shard reads the shards that have no pair. With no item,
	or with its map failing, a server that read every shard within Windows.DOWN answers from its own
	pairs. Any other server reads every shard. Reading merges each shard it read and answers the
	sum, or Unresolved while a shard has no pair. A missing item makes this server a taker once it
	has answered. So does an item whose holder's lease is past by Lapse on this server's clock. A
	server that holds the total already does not take it. Refreshing reads every shard, unless it
	read them all within Windows.REFRESH. Summarizing merges the pairs into the item by write count.
	It names this server the holder until Windows.LEASE past its clock. The transform cancels while
	another holder's lease is ahead. A holder refreshes again every Windows.REFRESH while this
	server read the total within Windows.HOLDING. A shard read that shows an entry Windows.PRUNE_AGE
	old sends that shard one tidy after the answer. It sends at most one tidy per shard per
	Windows.PRUNE_AGE. No pair is ever a sum this server made up: each is one its shard held.

	Return type: A table with Machine and Context. The type is Context.
	Example usage:
		local Sum = Runner.Run(Total.Machine, Total.Context(Held, 60, Server, Lapse), Places):Wait()
--]=]

local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Book = require("../Record/Book")
local Machine = require("../Machine/Machine")
local Totals = require("../Record/Totals")
local Types = require("../Record/Types")
local Windows = require("../Core/Constants/Windows")

type Said = number | Answer.Answer

export type Context = {
	read Held: Totals.Held,
	read MaxAge: number,
	read Server: number,
	read Lapse: number,
	Asked: { number },
	Tidy: { number },
	Refresh: boolean,
	Owns: boolean,
	Holder: boolean,
}

type Call = Machine.Call<Context, Said>

local STATE: {
	read Checking: "Checking",
	read Fetching: "Fetching",
	read Reading: "Reading",
	read Tidying: "Tidying",
	read Refreshing: "Refreshing",
	read Summarizing: "Summarizing",
	read Holding: "Holding",
	read Done: "Done",
} =
	{
		Checking = "Checking",
		Fetching = "Fetching",
		Reading = "Reading",
		Tidying = "Tidying",
		Refreshing = "Refreshing",
		Summarizing = "Summarizing",
		Holding = "Holding",
		Done = "Done",
	}

local WORD: {
	read Fresh: "Fresh",
	read Whole: "Whole",
	read Partial: "Partial",
	read Missing: "Missing",
	read Down: "Down",
	read Behind: "Behind",
} = {
	Fresh = "Fresh",
	Whole = "Whole",
	Partial = "Partial",
	Missing = "Missing",
	Down = "Down",
	Behind = "Behind",
}

local Total = {}

local function Ref(Held: Totals.Held, Index: number): Book.Ref
	return { Store = Held.Place, Key = Totals.Key(Held.Name, Held.Shards, Index) }
end

local function Every(Held: Totals.Held): { number }
	local Found: { number } = {}
	for Index = 0, Held.Shards - 1 do
		table.insert(Found, Index)
	end
	return Found
end

local function Lacking(Held: Totals.Held): { number }
	local Found: { number } = {}
	for Index = 0, Held.Shards - 1 do
		if Held.Pairs[Index] == nil then
			table.insert(Found, Index)
		end
	end
	return Found
end

local function Claim(Context: Context)
	local Held = Context.Held
	if not Held.Holding then
		Held.Holding, Context.Refresh, Context.Owns = true, true, true
	end
end

local function Release(Call: Call): string
	local Context = Call.Context
	if Context.Owns then
		Context.Held.Holding, Context.Owns = false, false
	end
	return STATE.Done
end

local function After(Call: Call): string
	local Context = Call.Context
	if Context.Tidy[1] then
		return STATE.Tidying
	elseif Context.Refresh then
		Context.Refresh = false
		return if Totals.Recent(Context.Held, Call.Now, Windows.REFRESH) then STATE.Summarizing else STATE.Refreshing
	elseif Context.Holder then
		return STATE.Holding
	end
	return Release(Call)
end

local function Check(Call: Call): string
	local Context = Call.Context
	local Held = Context.Held
	local Seen = Held.Seen
	local Sum = Totals.Sum(Held.Pairs, Held.Shards)
	Held.Called = Call.Now
	if Sum and Seen and Call.Now - Seen <= Context.MaxAge then
		Machine.Answer(Call, Sum)
		return WORD.Fresh
	end
	return Asks.SAID.Done
end

local function Fetch(Call: Call)
	local Held = Call.Context.Held
	Machine.Ask(Call, Asks.Item(Held.Map, Held.Item))
end

local function Fetched(Call: Call): string
	local Context, Reply = Call.Context, Machine.Reply(Call)
	local Held = Context.Held
	if Reply.Said == Asks.SAID.Failed then
		return WORD.Down
	elseif Reply.Value == nil then
		Claim(Context)
		Context.Asked = Every(Held)
		return WORD.Missing
	end
	local Found = Totals.Read(Reply.Value, Held.Shards)
	if Found == "Behind" then
		Machine.Answer(Call, Answer.Behind)
		return WORD.Behind
	end
	for Index, Pair in Found or {} do
		Totals.Take(Held, Index, Pair)
	end
	if Totals.Lapsed(Reply.Value, Call.Now, Context.Lapse) then
		Claim(Context)
	end
	local Sum = Totals.Sum(Held.Pairs, Held.Shards)
	if Sum then
		Held.Seen = Call.Now
		Machine.Answer(Call, Sum)
		return WORD.Whole
	end
	Context.Asked = Lacking(Held)
	return WORD.Partial
end

local function Down(Call: Call): string
	local Context = Call.Context
	local Held = Context.Held
	local Sum = Totals.Sum(Held.Pairs, Held.Shards)
	if Sum and Totals.Recent(Held, Call.Now, Windows.DOWN) then
		Machine.Answer(Call, Sum)
		return STATE.Done
	end
	Context.Asked = Every(Held)
	return STATE.Reading
end

local function Read(Call: Call)
	local Context = Call.Context
	for _, Index in Context.Asked do
		Machine.Ask(Call, Asks.Read(Ref(Context.Held, Index)))
	end
end

local function Merge(Call: Call)
	local Context = Call.Context
	local Held = Context.Held
	for Order, Index in Context.Asked do
		local Reply = Call.Heard[Order]
		if Reply and Reply.Said ~= Asks.SAID.Failed then
			Totals.Take(Held, Index, Totals.Pair(Reply.Value))
			Held.Read[Index] = Reply.Now
			local Tidied = Held.Tidied[Index]
			if Totals.Untidy(Reply.Value, Reply.Now) and (Tidied == nil or Reply.Now - Tidied >= Windows.PRUNE_AGE) then
				Held.Tidied[Index] = Reply.Now
				table.insert(Context.Tidy, Index)
			end
		end
	end
end

local function Gathered(Call: Call): string
	Merge(Call)
	local Held = Call.Context.Held
	local Sum = Totals.Sum(Held.Pairs, Held.Shards)
	if Sum then
		Held.Seen = Call.Now
	end
	Machine.Answer(Call, Sum or Answer.Unresolved)
	return Asks.SAID.Done
end

local function Tidy(Call: Call)
	local Context = Call.Context
	for _, Index in Context.Tidy do
		local Request: Types.Request = { Writer = 0, Ack = 0, MustExist = true, Ops = {}, Tidy = true }
		Machine.Ask(Call, Asks.Send(Ref(Context.Held, Index), Request))
	end
	table.clear(Context.Tidy)
end

local function Refresh(Call: Call)
	Call.Context.Asked = Every(Call.Context.Held)
	Read(Call)
end

local function Refreshed(Call: Call): string
	Merge(Call)
	return Asks.SAID.Done
end

local function Summarize(Call: Call)
	local Context = Call.Context
	local Held, Now, Server = Context.Held, Call.Now, Context.Server
	local Pairs = table.clone(Held.Pairs)
	local function Transform(Current: unknown): unknown
		return Totals.Summary(Current, Pairs, Held.Shards, Server, Now, Now + Windows.LEASE)
	end
	Machine.Ask(Call, Asks.Change(Held.Map, Held.Item, Transform, Windows.SUMMARY))
end

local function Summarized(Call: Call): string
	local Context, Reply = Call.Context, Machine.Reply(Call)
	local Held = Context.Held
	local Found = if Reply.Said == Asks.SAID.Failed then nil else Totals.Read(Reply.Value, Held.Shards)
	Context.Holder = type(Found) == "table"
	if type(Found) == "table" then
		for Index, Pair in Found do
			Totals.Take(Held, Index, Pair)
		end
	end
	return Asks.SAID.Done
end

local function Hold(Call: Call)
	Machine.Ask(Call, Asks.Wait(Windows.REFRESH))
end

local function Held(Call: Call): string
	local Context = Call.Context
	if Call.Now - Context.Held.Called <= Windows.HOLDING then
		return STATE.Refreshing
	end
	Context.Holder = false
	return Release(Call)
end

local STATES: { [string]: Machine.State<Context, Said> } = {
	[STATE.Checking] = {
		Hear = Check,
		On = {
			{ Said = WORD.Fresh, Go = STATE.Done },
		},
		Else = STATE.Fetching,
	},
	[STATE.Fetching] = {
		Enter = Fetch,
		Hear = Fetched,
		On = {
			{ Said = WORD.Behind, Go = STATE.Done },
			{ Said = WORD.Whole, Go = After },
			{ Said = WORD.Down, Go = Down },
		},
		Else = STATE.Reading,
	},
	[STATE.Reading] = {
		Enter = Read,
		Hear = Gathered,
		Else = After,
	},
	[STATE.Tidying] = {
		Enter = Tidy,
		Else = After,
	},
	[STATE.Refreshing] = {
		Enter = Refresh,
		Hear = Refreshed,
		Else = STATE.Summarizing,
	},
	[STATE.Summarizing] = {
		Enter = Summarize,
		Hear = Summarized,
		Else = After,
	},
	[STATE.Holding] = {
		Enter = Hold,
		Else = Held,
	},
	[STATE.Done] = {},
}

function Total.Context(Held: Totals.Held, MaxAge: number, Server: number, Lapse: number): Context
	return {
		Held = Held,
		MaxAge = MaxAge,
		Server = Server,
		Lapse = Lapse,
		Asked = {},
		Tidy = {},
		Refresh = false,
		Owns = false,
		Holder = false,
	}
end

Total.Machine = Machine.Define({ Name = "Total", Initial = STATE.Checking, States = STATES })

return Total
