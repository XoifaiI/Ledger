--!strict
--!optimize 2

--[=[
	Total: Machine. Answers a total, and keeps its summary item while this server holds it.

	The answer is the sum of each value of the pairs, a list as wide as the kind's pairs. No pair is
	ever a sum this server made up: each is one its shard held. The machine answers from this
	server's pairs when every shard has one and its last full view is within MaxAge. Else it gets the
	summary item and merges its pairs by write count. An item of a newer format answers Behind, and
	an item that lacks a shard reads the shards that have no pair. With no item, or with its map
	failing, a server that read every shard within Shards.DOWN answers from its own pairs, and any
	other server reads every shard. A sum is Unresolved while a shard has no pair.

	The machine runs on after it answers. A missing item makes this server a taker, and so does an
	item whose holder's lease is past by Lapse on this server's clock. A server that holds the total
	already does not take it. A taker reads every shard, unless it read them all within
	Windows.REFRESH, and merges its pairs into the item. The item names this server the holder until
	Windows.LEASE past its clock, and its transform cancels while another holder's lease is ahead. A
	holder refreshes every Windows.REFRESH while this server read the total within Shards.HOLDING. A
	shard read that shows an entry Shards.PRUNE_AGE old sends that shard one tidy, at most one per
	shard per Shards.PRUNE_AGE.

	Return type: The Total module, and the Context type.
	Example usage:
		local Sum = Runner.Run(Total.Machine, Total.Context(Held, 60, Server, Lapse), Places):Wait()
--]=]

local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Book = require("../Record/Book")
local Machine = require("../Machine/Machine")
local Requests = require("../Record/Requests")
local Shards = require("../Record/Shards")
local Windows = require("../Core/Constants/Windows")

type Said = { number } | Answer.Answer

export type Context = {
	read Held: Shards.Held,
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

local STATE = {
	Checking = "Checking" :: "Checking",
	Fetching = "Fetching" :: "Fetching",
	Reading = "Reading" :: "Reading",
	Tidying = "Tidying" :: "Tidying",
	Refreshing = "Refreshing" :: "Refreshing",
	Summarizing = "Summarizing" :: "Summarizing",
	Holding = "Holding" :: "Holding",
	Done = "Done" :: "Done",
}

local WORD = {
	Fresh = "Fresh" :: "Fresh",
	Whole = "Whole" :: "Whole",
	Partial = "Partial" :: "Partial",
	Missing = "Missing" :: "Missing",
	Down = "Down" :: "Down",
	Behind = "Behind" :: "Behind",
}

local Total = {}

local function Ref(Held: Shards.Held, Index: number): Book.Ref
	return { Store = Held.Place, Key = Shards.Key(Held.Name, Held.Shards, Index, Held.Kind.Prefix) }
end

local function Every(Held: Shards.Held): { number }
	local Found: { number } = {}
	for Index = 0, Held.Shards - 1 do
		table.insert(Found, Index)
	end
	return Found
end

local function Lacking(Held: Shards.Held): { number }
	local Found: { number } = {}
	for Index = 0, Held.Shards - 1 do
		if Held.Pairs[Index] == nil then
			table.insert(Found, Index)
		end
	end
	return Found
end

local function Claim(Context: Context)
	if Shards.StartHolding(Context.Held) then
		Context.Refresh = true
		Context.Owns = true
	end
end

local function Release(Call: Call): string
	local Context = Call.Context
	if Context.Owns then
		Shards.StopHolding(Context.Held)
		Context.Owns = false
	end
	return STATE.Done
end

local function After(Call: Call): string
	local Context = Call.Context
	if Context.Tidy[1] then
		return STATE.Tidying
	elseif Context.Refresh then
		Context.Refresh = false
		return if Shards.Recent(Context.Held, Call.Now, Windows.REFRESH) then STATE.Summarizing else STATE.Refreshing
	elseif Context.Holder then
		return STATE.Holding
	end
	return Release(Call)
end

local function Check(Call: Call): string
	local Context = Call.Context
	local Held = Context.Held
	local Seen = Held.Seen
	local Sum = Shards.Sum(Held.Pairs, Held.Shards, Held.Kind.Width)
	Shards.NoteCall(Held, Call.Now)
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
	local Found = Shards.Read(Reply.Value, Held.Shards, Held.Kind.Width)
	if Found == "Behind" then
		Machine.Answer(Call, Answer.Behind)
		return WORD.Behind
	end
	for Index, Pair in Found or {} do
		Shards.Take(Held, Index, Pair)
	end
	if Shards.Lapsed(Reply.Value, Call.Now, Context.Lapse) then
		Claim(Context)
	end
	local Sum = Shards.Sum(Held.Pairs, Held.Shards, Held.Kind.Width)
	if Sum then
		Shards.NoteFullView(Held, Call.Now)
		Machine.Answer(Call, Sum)
		return WORD.Whole
	end
	Context.Asked = Lacking(Held)
	return WORD.Partial
end

local function Down(Call: Call): string
	local Context = Call.Context
	local Held = Context.Held
	local Sum = Shards.Sum(Held.Pairs, Held.Shards, Held.Kind.Width)
	if Sum and Shards.Recent(Held, Call.Now, Shards.DOWN) then
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
			Shards.TakeRead(Held, Index, Reply.Value, Reply.Now)
			if Shards.StartTidy(Held, Index, Reply.Value, Reply.Now) then
				table.insert(Context.Tidy, Index)
			end
		end
	end
end

local function Gathered(Call: Call): string
	Merge(Call)
	local Held = Call.Context.Held
	local Sum = Shards.Sum(Held.Pairs, Held.Shards, Held.Kind.Width)
	if Sum then
		Shards.NoteFullView(Held, Call.Now)
	end
	Machine.Answer(Call, Sum or Answer.Unresolved)
	return Asks.SAID.Done
end

local function Tidy(Call: Call)
	local Context = Call.Context
	for _, Index in Context.Tidy do
		Machine.Ask(Call, Asks.Send(Ref(Context.Held, Index), Requests.Tidy()))
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
		return Shards.Summary(Current, Pairs, Held.Shards, Held.Kind.Width, Server, Now, Now + Windows.LEASE)
	end
	Machine.Ask(Call, Asks.Change(Held.Map, Held.Item, Transform, Shards.SUMMARY))
end

local function Summarized(Call: Call): string
	local Context, Reply = Call.Context, Machine.Reply(Call)
	local Held = Context.Held
	local Found = if Reply.Said == Asks.SAID.Failed then nil else Shards.Read(Reply.Value, Held.Shards, Held.Kind.Width)
	Context.Holder = type(Found) == "table"
	if type(Found) == "table" then
		for Index, Pair in Found do
			Shards.Take(Held, Index, Pair)
		end
	end
	return Asks.SAID.Done
end

local function Hold(Call: Call)
	Machine.Ask(Call, Asks.Wait(Windows.REFRESH))
end

local function Held(Call: Call): string
	local Context = Call.Context
	if Call.Now - Context.Held.Called <= Shards.HOLDING then
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

function Total.Context(Held: Shards.Held, MaxAge: number, Server: number, Lapse: number): Context
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
