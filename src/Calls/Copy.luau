--!strict
--!optimize 2

--[=[

	Copy: Machine. Follows a key through its copy in MemoryStore, and keeps the copy while this server
	holds it.

	Spec: extras 4 and 5.2 to 5.3; cuts 3.4 step 7. Model: Copy.tla and CopyAbs.tla.

	Follow runs while the key is followed, or once for a Peek with a MaxAge. Checking answers a Peek
	from the state this server last showed when it is younger than MaxAge. A holder refreshes. Any
	other call ticks. Ticking gets the header. A header with a write count above the one this server
	showed shows its state. A header with parts reads the parts of its slot. It shows them only when
	every part carries the header's write count. After two such misses in a row, the follower
	refreshes as a taker. It also refreshes as a taker when it finds no header, or a holder's lease
	past by Lapse. A header of a newer format answers Behind. With the map failing, or a big header,
	the follower reads the key itself, at most once every Windows.FOLLOW_EVERY. A Peek always reads
	it. A read that finds the key gone takes the copy off and shows nothing. Every state goes through
	the shown table and then to Show. A follower never shows an older state. A follower rests
	Windows.TICK, doubling while the write count stands, up to Windows.TICK_MAX. A holder rests
	Windows.CHECK. The machine stops once nothing follows the key, and lets its lease lapse.

	Refresh reads the key as Peek does, through the shown table and the transaction's read rule. A key
	that is gone takes the copy off and shows nothing. The holder sends the state when its write count
	is above the one it sent, or when its last push is half of Windows.COPY old. A taker sends it on
	its first refresh. A state that fits goes in the header. Else every part goes into its slot first,
	and then the header. A state past the parts sends a big header. Otherwise the holder renews its
	lease only when the lease ends within Windows.REFRESH. The header's transform keeps the larger
	write count, and cancels while another holder's lease is ahead. Refresh answers whether this
	server holds the copy, with the view it read.

	Clear takes off a key's copy, the header and both slots of parts, once its header is read.

	Context makes a follower's context. A Peek sets Once and MaxAge on it. A follow sets Followed and
	Show. Followed says whether anything still follows the key, and Show hears each state the
	follower shows.

	Return type: A table with Follow, Refresh, Clear and Context. The types are Context and Refreshed.
	Example usage:
		local State = Runner.Run(Copy.Follow, Copy.Context(Held, Build, Table, Server, Lapse), Places):Wait()
--]=]

local Answer = require("../Core/Answer")
local Asks = require("../Machine/Asks")
local Backoff = require("../Machine/Backoff")
local Copies = require("../Record/Copies")
local Limits = require("../Core/Constants/Limits")
local Machine = require("../Machine/Machine")
local Peek = require("./Peek")
local Shown = require("../Record/Shown")
local Types = require("../Record/Types")
local View = require("../Record/View")
local Windows = require("../Core/Constants/Windows")

type State = { [string]: any }
type Shows = State | Answer.Answer

export type Context = {
	read Held: Copies.Held,
	read Build: Types.Build,
	read Shown: Shown.Shown,
	read Server: number,
	read Lapse: number,
	Once: boolean,
	MaxAge: number,
	Followed: (() -> boolean)?,
	Show: ((State: State) -> ())?,
	Header: Copies.Header?,
}

export type Refreshed = {
	read Holder: boolean,
	read View: View.View?,
	read Gone: boolean,
}

type Fixing = {
	read Held: Copies.Held,
	read Build: Types.Build,
	read Shown: Shown.Shown,
	read Server: number,
	View: View.View?,
	Fresh: Copies.Fresh?,
	Pieces: { unknown },
	Until: number,
}

type Call = Machine.Call<Context, Shows>
type Fix = Machine.Call<Fixing, Refreshed>
type Clearing = Machine.Call<Copies.Held, boolean>

local STATE: {
	read Checking: "Checking",
	read Ticking: "Ticking",
	read Parting: "Parting",
	read Direct: "Direct",
	read Refreshing: "Refreshing",
	read Resting: "Resting",
	read Reading: "Reading",
	read Putting: "Putting",
	read Heading: "Heading",
	read Clearing: "Clearing",
	read Fetching: "Fetching",
	read Done: "Done",
} =
	{
		Checking = "Checking",
		Ticking = "Ticking",
		Parting = "Parting",
		Direct = "Direct",
		Refreshing = "Refreshing",
		Resting = "Resting",
		Reading = "Reading",
		Putting = "Putting",
		Heading = "Heading",
		Clearing = "Clearing",
		Fetching = "Fetching",
		Done = "Done",
	}

local WORD: {
	read Young: "Young",
	read Hold: "Hold",
	read Down: "Down",
	read Take: "Take",
	read Parts: "Parts",
	read Rest: "Rest",
	read Read: "Read",
	read Gone: "Gone",
	read Push: "Push",
	read Head: "Head",
	read Found: "Found",
} =
	{
		Young = "Young",
		Hold = "Hold",
		Down = "Down",
		Take = "Take",
		Parts = "Parts",
		Rest = "Rest",
		Read = "Read",
		Gone = "Gone",
		Push = "Push",
		Head = "Head",
		Found = "Found",
	}

local Copy = {}

local function Settle(Call: Call, Value: Shows)
	if Call.Answered == nil then
		Machine.Answer(Call, Value)
	end
end

local function Showing(Call: Call, Found: Shows, Writes: number)
	local Context = Call.Context
	local Held = Context.Held
	if type(Found) ~= "table" then
		Settle(Call, Found)
		return
	elseif not Context.Shown:Allows(Held.Mark, Writes) then
		Settle(Call, Held.State or Answer.Unresolved)
		return
	end
	Context.Shown:Show(Held.Mark, Writes)
	if Writes > Held.Writes or Held.State == nil then
		Held.Writes, Held.State, Held.Stands = Writes, Found, 0
		local Show = Context.Show
		if Show then
			Show(Found)
		end
	end
	Held.At, Held.Misses = Call.Now, 0
	Settle(Call, Held.State :: State)
end

local function Gone(Held: Copies.Held)
	Held.Writes, Held.State, Held.At = 0, nil, nil
end

local function Check(Call: Call): string
	local Context = Call.Context
	local Held = Context.Held
	local At = Held.At
	if Context.Once and Held.State and At and Call.Now - At <= Context.MaxAge then
		Machine.Answer(Call, Held.State :: State)
		return WORD.Young
	elseif Held.Holder and not Context.Once then
		return WORD.Hold
	end
	return Asks.SAID.Done
end

local function Tick(Call: Call)
	local Held = Call.Context.Held
	Machine.Ask(Call, Asks.Item(Held.Map, Held.Header))
end

local function Lapsed(Call: Call, Header: Copies.Header): string
	return if Copies.Lapsed(Header, Call.Now, Call.Context.Lapse) then WORD.Take else WORD.Rest
end

local function Ticked(Call: Call): string
	local Context, Reply = Call.Context, Machine.Reply(Call)
	local Held = Context.Held
	if Reply.Said == Asks.SAID.Failed then
		return WORD.Down
	elseif Reply.Value == nil then
		return WORD.Take
	end
	local Header = Copies.Read(Reply.Value)
	if Header == "Behind" then
		Settle(Call, Answer.Behind)
		return WORD.Rest
	elseif Header == nil or Header.Parts == Copies.BIG then
		return WORD.Down
	elseif Header.Writes <= Held.Writes then
		Held.Stands += 1
		Held.At, Held.Misses = Call.Now, 0
		Settle(Call, Held.State or Answer.Unresolved)
		return Lapsed(Call, Header)
	end
	Context.Header = Header
	local State = Header.State
	if State then
		Showing(Call, Copies.Show(Header, State, Context.Build), Header.Writes)
		return Lapsed(Call, Header)
	end
	return WORD.Parts
end

local function Parts(Call: Call)
	local Context = Call.Context
	local Held, Header = Context.Held, Context.Header :: Copies.Header
	for Index = 0, Header.Parts - 1 do
		Machine.Ask(Call, Asks.Item(Held.Map, Copies.Part(Held.Ref, Header.Writes, Index)))
	end
end

local function Parted(Call: Call): string
	local Context = Call.Context
	local Held, Header = Context.Held, Context.Header :: Copies.Header
	local Values: { unknown } = {}
	for Index, Reply in Call.Heard do
		Values[Index] = if Reply.Said == Asks.SAID.Failed then nil else Reply.Value
	end
	local State = Copies.Join(Header, Values)
	if State then
		Showing(Call, Copies.Show(Header, State, Context.Build), Header.Writes)
		return Lapsed(Call, Header)
	end
	Held.Misses += 1
	if Held.Misses >= Limits.COPY_MISSES then
		return WORD.Take
	end
	return if Context.Once then WORD.Down else WORD.Rest
end

local function Direct(Call: Call)
	local Context = Call.Context
	local Held, Read = Context.Held, Context.Held.Read
	if Context.Once or Read == nil or Call.Now - Read >= Windows.FOLLOW_EVERY then
		Machine.Ask(Call, Asks.Run(Peek.Cached, Peek.Context(Held.Ref, Context.Build, Context.Shown)))
	end
end

local function Directed(Call: Call): string
	local Context = Call.Context
	local Reply = Call.Heard[1]
	if Reply == nil then
		return WORD.Rest
	end
	Context.Held.Read = Call.Now
	local Found = Reply.Answer
	if type(Found) == "table" then
		local Seen = Found :: View.View
		Showing(Call, Seen.State, Seen.Writes)
	elseif Found == Answer.Missing then
		Gone(Context.Held)
		Settle(Call, Answer.Missing)
		return WORD.Gone
	else
		Settle(Call, (Found or Answer.Unresolved) :: Answer.Answer)
	end
	return WORD.Rest
end

local function Take(Call: Call)
	local Context = Call.Context
	local Fixing: Fixing = {
		Held = Context.Held,
		Build = Context.Build,
		Shown = Context.Shown,
		Server = Context.Server,
		Pieces = {},
		Until = 0,
	}
	Machine.Ask(Call, Asks.Run(Copy.Refresh, Fixing))
end

local function Taken(Call: Call): string
	local Context, Reply = Call.Context, Machine.Reply(Call)
	local Got = Reply.Answer
	local Done: Refreshed? = if type(Got) == "table" then Got :: Refreshed else nil
	local Held = Context.Held
	Held.Holder = Done ~= nil and Done.Holder
	local Seen = if Done then Done.View else nil
	if Seen then
		Showing(Call, Seen.State, Seen.Writes)
	elseif Done and Done.Gone then
		Gone(Held)
		Settle(Call, Answer.Missing)
	end
	Settle(Call, Held.State or Answer.Unresolved)
	return WORD.Rest
end

local function Rest(Call: Call): string
	local Context = Call.Context
	local Held = Context.Held
	local Followed = Context.Followed
	if Context.Once then
		Settle(Call, Held.State or Answer.Unresolved)
		return STATE.Done
	elseif Followed == nil or not Followed() then
		Held.Running, Held.Holder = false, false
		return STATE.Done
	end
	return STATE.Resting
end

local function Drop(Call: Machine.Call<any, any>, Held: Copies.Held)
	Machine.Ask(Call, Asks.Drop(Held.Map, Held.Header))
	for Slot = 0, 1 do
		for Index = 0, Limits.PARTS_MAX - 1 do
			Machine.Ask(Call, Asks.Drop(Held.Map, Copies.Part(Held.Ref, Slot, Index)))
		end
	end
end

local function Wipe(Call: Call)
	Drop(Call, Call.Context.Held)
end

local function Wait(Call: Call)
	local Held = Call.Context.Held
	local Tick = Backoff.Retry(Held.Stands + 1, Windows.TICK, Windows.TICK_MAX)
	Machine.Ask(Call, Asks.Wait(if Held.Holder then Windows.CHECK else Tick))
end

local TAKE = { Said = WORD.Take, Go = STATE.Refreshing }
local DOWN = { Said = WORD.Down, Go = STATE.Direct }

local FOLLOW: { [string]: Machine.State<Context, Shows> } = {
	[STATE.Checking] = {
		Hear = Check,
		On = {
			{ Said = WORD.Young, Go = STATE.Done },
			{ Said = WORD.Hold, Go = STATE.Refreshing },
		},
		Else = STATE.Ticking,
	},
	[STATE.Ticking] = {
		Enter = Tick,
		Hear = Ticked,
		On = { TAKE, DOWN, { Said = WORD.Parts, Go = STATE.Parting } },
		Else = Rest,
	},
	[STATE.Parting] = {
		Enter = Parts,
		Hear = Parted,
		On = { TAKE, DOWN },
		Else = Rest,
	},
	[STATE.Direct] = {
		Enter = Direct,
		Hear = Directed,
		On = {
			{ Said = WORD.Gone, Go = STATE.Clearing },
		},
		Else = Rest,
	},
	[STATE.Clearing] = {
		Enter = Wipe,
		Else = Rest,
	},
	[STATE.Refreshing] = {
		Enter = Take,
		Hear = Taken,
		Else = Rest,
	},
	[STATE.Resting] = {
		Enter = Wait,
		Else = STATE.Checking,
	},
	[STATE.Done] = {},
}

local function Look(Call: Fix)
	local Context = Call.Context
	Machine.Ask(Call, Asks.Run(Peek.Cached, Peek.Context(Context.Held.Ref, Context.Build, Context.Shown)))
end

local function Keep(Call: Fix, Holder: boolean)
	Machine.Answer(Call, { Holder = Holder, View = Call.Context.View, Gone = false })
end

local function Looked(Call: Fix): string
	local Context = Call.Context
	local Held = Context.Held
	local Found = Machine.Reply(Call).Answer
	if Found == Answer.Missing then
		return WORD.Gone
	elseif type(Found) ~= "table" then
		Keep(Call, Held.Holder)
		return Asks.SAID.Done
	end
	local Seen = Found :: View.View
	Context.View = Seen
	Context.Until = Call.Now + Windows.LEASE
	local Pushed = Held.Pushed
	if Seen.Writes > Held.Sent or Pushed == nil or Call.Now - Pushed >= Windows.REPUSH or not Held.Holder then
		local Fresh, Pieces = Copies.Content(Seen.Writes, Seen.Level, Seen.Floor, Seen.State)
		Context.Fresh, Context.Pieces = Fresh, Pieces
		return if Pieces[1] then WORD.Push else WORD.Head
	end
	local Until = Held.Until
	if Until and Until - Call.Now > Windows.REFRESH then
		Keep(Call, true)
		return Asks.SAID.Done
	end
	return WORD.Head
end

local function Push(Call: Fix)
	local Context = Call.Context
	local Held, Fresh = Context.Held, Context.Fresh :: Copies.Fresh
	for Index, Piece in Context.Pieces do
		Machine.Ask(Call, Asks.Put(Held.Map, Copies.Part(Held.Ref, Fresh.Writes, Index - 1), Piece, Windows.COPY))
	end
end

local function Pushed(Call: Fix): string
	for _, Reply in Call.Heard do
		if Reply.Said == Asks.SAID.Failed then
			Keep(Call, Call.Context.Held.Holder)
			return Asks.SAID.Done
		end
	end
	return WORD.Head
end

local function Head(Call: Fix)
	local Context = Call.Context
	local Held, Fresh, Server, Now, Until = Context.Held, Context.Fresh, Context.Server, Call.Now, Context.Until
	local function Transform(Current: unknown): unknown
		return Copies.Merge(Current, Fresh, Server, Now, Until)
	end
	Machine.Ask(Call, Asks.Change(Held.Map, Held.Header, Transform, Windows.COPY))
end

local function Headed(Call: Fix): string
	local Context, Reply = Call.Context, Machine.Reply(Call)
	local Held = Context.Held
	local Header = if Reply.Said == Asks.SAID.Failed then nil else Copies.Read(Reply.Value)
	if type(Header) == "table" then
		Held.Sent, Held.Until = math.max(Held.Sent, Header.Writes), Context.Until
		if Context.Fresh then
			Held.Pushed = Call.Now
		end
	end
	Keep(Call, type(Header) == "table")
	return Asks.SAID.Done
end

local function Clear(Call: Fix)
	Drop(Call, Call.Context.Held)
end

local function Cleared(Call: Fix): string
	Machine.Answer(Call, { Holder = false, Gone = true })
	return Asks.SAID.Done
end

local REFRESH: { [string]: Machine.State<Fixing, Refreshed> } = {
	[STATE.Reading] = {
		Enter = Look,
		Hear = Looked,
		On = {
			{ Said = WORD.Gone, Go = STATE.Clearing },
			{ Said = WORD.Push, Go = STATE.Putting },
			{ Said = WORD.Head, Go = STATE.Heading },
		},
		Else = STATE.Done,
	},
	[STATE.Putting] = {
		Enter = Push,
		Hear = Pushed,
		On = {
			{ Said = WORD.Head, Go = STATE.Heading },
		},
		Else = STATE.Done,
	},
	[STATE.Heading] = {
		Enter = Head,
		Hear = Headed,
		Else = STATE.Done,
	},
	[STATE.Clearing] = {
		Enter = Clear,
		Hear = Cleared,
		Else = STATE.Done,
	},
	[STATE.Done] = {},
}

local function Fetch(Call: Clearing)
	local Held = Call.Context
	Machine.Ask(Call, Asks.Item(Held.Map, Held.Header))
end

local function Fetched(Call: Clearing): string
	local Reply = Machine.Reply(Call)
	return if Reply.Said == Asks.SAID.Failed or Reply.Value ~= nil then WORD.Found else Asks.SAID.Done
end

local function Erase(Call: Clearing)
	Drop(Call, Call.Context)
end

local function Wiped(Call: Clearing): string
	Machine.Answer(Call, true)
	return Asks.SAID.Done
end

local CLEAR: { [string]: Machine.State<Copies.Held, boolean> } = {
	[STATE.Fetching] = {
		Enter = Fetch,
		Hear = Fetched,
		On = {
			{ Said = WORD.Found, Go = STATE.Clearing },
		},
		Else = STATE.Done,
	},
	[STATE.Clearing] = {
		Enter = Erase,
		Hear = Wiped,
		Else = STATE.Done,
	},
	[STATE.Done] = {},
}

function Copy.Context(Held: Copies.Held, Build: Types.Build, Table: Shown.Shown, Server: number, Lapse: number): Context
	return {
		Held = Held,
		Build = Build,
		Shown = Table,
		Server = Server,
		Lapse = Lapse,
		Once = false,
		MaxAge = 0,
	}
end

Copy.Follow = Machine.Define({ Name = "Follow", Initial = STATE.Checking, States = FOLLOW })
Copy.Refresh = Machine.Define({ Name = "Refresh", Initial = STATE.Reading, States = REFRESH })
Copy.Clear = Machine.Define({ Name = "Clear", Initial = STATE.Fetching, States = CLEAR })

return Copy
