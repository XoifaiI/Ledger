--!strict
--!optimize 2

--[=[
	Refusals: One rule per case for everything Ledger turns away.

	Two different things are refused here. A caller that asked for something impossible gets a throw
	where the call was written. A caller that asked for something reasonable that cannot happen now
	gets a reason.
	The reasons matter as much as the refusals. Behind promises nothing was written, Unresolved
	promises nothing either way, and Refused says the reducer said no.

	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, and it runs the next time you press play.
--]=]

local Suite = require("../Suite")

local Fault = Suite.Fault
local Insides = Suite.Insides
local Reducers = Suite.Reducers

local Future = Insides.Future
local Log = Insides.Log
local MakeOp = Insides.MakeOp
local NoYield = Insides.NoYield
local Broke = Insides.Fault
local RetryAsync = Insides.RetryAsync
local Transfer = Insides.Transfer
local Fold = Insides.Fold
local Ledger = Insides.Ledger
local Tx = Insides.Tx

type Case = Suite.Case
type Fixture = Suite.Fixture

local Keep = Reducers.Keep
local Adder = Reducers.Adder

local Cases = Suite.File("Refusals")

local function Plain(T: Case, Keys: string?, Reducer: any?, Data: string?): Fixture
	return T:Store({
		Keys = Keys or "Player",
		Default = Reducers.PLAIN,
		Reducer = Reducer or Keep,
		Data = Data,
	})
end

local function Purse(T: Case, Data: string?): Fixture
	return T:Store({
		Default = Reducers.PLAIN,
		Balance = "Gold",
		Reducer = Adder,
		Data = Data,
	})
end

local function Refused(Options: any): boolean
	local Ok, Built = pcall(Ledger.New, Options)
	if Ok then
		Built:Destroy()
	end
	return not Ok
end

Cases.Case("New refuses a config it cannot honour", function(T: Case)
	T:Is("no name", Refused({ Reducer = Keep, Default = {} }), true)
	T:Is("no reducer", Refused({ Name = "GuardA", Default = {} }), true)
	T:Is("a default using the reserved underscore prefix", Refused({ Name = "GuardB", Reducer = Keep, Default = { _Mine = 1 } }), true)
	T:Is("a default a datastore cannot hold", Refused({ Name = "GuardC", Reducer = Keep, Default = { Callback = Keep } }), true)
	T:Is("a migration that is not a step", Refused({ Name = "GuardD", Reducer = Keep, Default = {}, Migrations = { 5 } }), true)
	T:Is("a balance that is not a field name", Refused({ Name = "GuardE", Reducer = Keep, Default = { Gold = 0 }, Balance = 5 }), true)
	T:Is("a balance naming a field that is not a number", Refused({ Name = "GuardF", Reducer = Keep, Default = { Gold = "lots" }, Balance = "Gold" }), true)
	T:Is("a default holding a buffer", Refused({ Name = "GuardG", Reducer = Keep, Default = { Blob = buffer.fromstring("x") } }), false)
	T:Is("a name past the length limit", Refused({ Name = string.rep("x", 48), Reducer = Keep, Default = {} }), true)
end)

Cases.Case("a store cannot steal another's transaction table", function(T: Case)
	local Store = Plain(T, "String", nil, "CaseClash")
	local Name = Store.Store.Options.Name

	T:Is("claiming another store's transaction table as a store name", Refused({ Name = `{Name}_Tx`, Reducer = Keep, Default = {} }), true)
end)

Cases.Case("a reducer returning something else is skipped", function(T: Case)
	local function Banana(State: any, Op: any): any?
		if Op.Kind == "Bad" then
			return "banana"
		elseif Op.Kind == "Good" then
			local Next = table.clone(State)
			Next.Gold += 1
			return Next
		end
		return nil
	end

	local Store = Plain(T, "String", Banana)
	local Active: any = Store:Session("guardred")
	local Bad = Active:Apply("Bad")
	local Good = Active:Apply("Good")
	local State = Active:Get()

	local Folded: any = Fold({ Gold = 5 }, { { Id = "x", Kind = "Bad" } :: any }, Banana)

	T:Is("applying an op whose reducer returns a string", Bad, false)
	T:Is("applying a good one after it", Good, true)
	T:Is("the state is still a table", type(State), "table")
	T:Is("gold", State.Gold, 1)
	T:Is("folding past a reducer that returned a string", Folded.Gold, 5)
end)

Cases.Case("MakeOp refuses junk and owns the reserved fields", function(T: Case)
	local Make: any = MakeOp.New
	T:Is("a kind that is not a string", pcall(Make, 5), false)
	T:Is("an empty kind", pcall(Make, ""), false)
	T:Is("fields that are not a table", pcall(Make, "K", 5), false)

	local Clobbered: any = MakeOp.New("K", { Id = "mine", Kind = "Fake", Amount = 1 })
	T:Is("an Id the caller tried to set", Clobbered.Id ~= "mine", true)
	T:Is("the kind it was asked for", Clobbered.Kind, "K")
	T:Is("a field it was given", Clobbered.Amount, 1)
end)

Cases.Case("a string store refuses every key it cannot use", function(T: Case)
	local Store = Plain(T, "String")

	local function Peeking(Key: any): boolean
		return not (pcall(function()
			Store.Store:Peek(Key)
		end))
	end

	T:Is("a number key", Peeking(261), true)
	T:Is("an empty key", Peeking(""), true)
	T:Is("a key past the length limit", Peeking(string.rep("k", 51)), true)
	T:Is("a key that is not valid utf8", Peeking("\255\254"), true)
	T:Throws("loading a player into a string store", function()
		Store.Store:Load(nil :: any)
	end)
end)

Cases.Case("a string store takes a key with a space in it", function(T: Case)
	local function Set(State: any, Op: any): any?
		if Op.Kind ~= "Set" then
			return nil
		end
		local Next = table.clone(State)
		Next.Gold = Op.Amount
		return Next
	end

	local Store = Plain(T, "String", Set)
	Store.Store:Edit("clan one", "Set", { Amount = 5 }):Wait()

	T:Is("gold on a key with a space", Store:Amount("clan one"), 5)
end)

Cases.Case("a player store refuses every id it cannot use", function(T: Case)
	local Store = Plain(T, "Player")

	T:Throws("peeking a string", function()
		Store.Store:Peek("abc")
	end)
	T:Throws("editing nil", function()
		Store.Store:Edit(nil :: any, "K")
	end)
	T:Throws("resetting a negative id", function()
		Store.Store:Reset(-1)
	end)
end)

Cases.Case("Transfer refuses terms it cannot honour", function(T: Case)
	local Store = T:Store({ Keys = "Player", Default = Reducers.PLAIN, Balance = "Gold", Reducer = Adder })

	T:Throws("a transfer to the same key", function()
		Store.Store:Transfer(5, 5, 10)
	end)
	T:Throws("a fractional user id", function()
		Store.Store:Transfer(0.5, 2, 10)
	end)
	T:Throws("a zero amount", function()
		Store.Store:Transfer(1, 2, 0)
	end)
	T:Throws("a nan amount", function()
		Store.Store:Transfer(1, 2, 0 / 0)
	end)
end)

Cases.Case("a store with no balance refuses the money api", function(T: Case)
	local Store = Plain(T, "Player")

	T:Throws("transferring without a Balance field", function()
		Store.Store:Transfer(11, 12, 10)
	end)
	T:Throws("recovering transfers without one", function()
		Store.Store:RecoverTransfers(11)
	end)
end)

Cases.Case("Tx refuses a leg it cannot trust", function(T: Case)
	local Store = Plain(T, "Player")

	T:Throws("a leg with a junk user id", function()
		Store.Store:Tx("junkkey", { { UserId = "x", Kind = "K" }, { UserId = 2, Kind = "K" } })
	end)
	T:Throws("no transaction id", function()
		Store.Store:Tx({ { UserId = 1, Kind = "K" }, { UserId = 2, Kind = "K" } } :: any)
	end)
	T:Throws("a single leg", function()
		Store.Store:Tx("oneleg", { { UserId = 1, Kind = "K" } })
	end)
	T:Throws("fields that are not a table", function()
		Store.Store:Tx("badfields", { { UserId = 1, Kind = "K", Fields = "nope" :: any }, { UserId = 2, Kind = "K" } })
	end)

	local Held, Why = Store.Store
		:Tx("unstorable", {
			{ UserId = 1, Kind = "K", Fields = { Thing = workspace } },
			{ UserId = 2, Kind = "K" },
		})
		:Wait()
	T:Is("fields a datastore cannot hold", Held, false)
	T:Is("the reason for fields it cannot hold", Why, "Invalid")

	local Named, NamedWhy = Store.Store
		:Tx("reserved", {
			{ UserId = 1, Kind = "K", Fields = { Tx = "hax" } },
			{ UserId = 2, Kind = "K" },
		})
		:Wait()
	T:Is("fields using a reserved name", Named, false)
	T:Is("the reason for a reserved name", NamedWhy, "Invalid")

	local Owned, OwnedWhy = Store.Store
		:Tx("ownedkind", {
			{ UserId = 1, Kind = "__TransferDeliver" },
			{ UserId = 2, Kind = "K" },
		})
		:Wait()
	T:Is("a kind Ledger owns", Owned, false)
	T:Is("the reason for a kind Ledger owns", OwnedWhy, "Invalid")

	T:Throws("a store that Ledger did not build", function()
		Store.Store:Tx("junkstore", {
			{ UserId = 1, Kind = "K" },
			{ Store = {} :: any, Key = "clan x", Kind = "K" },
		})
	end)
end)

Cases.Case("a cross store Tx refuses when the far store cannot afford", function(T: Case)
	local function Move(State: any, Op: any): any?
		if Op.Kind ~= "Move" then
			return nil
		end
		local Gold = State.Gold + Op.Amount
		if Gold < 0 then
			return nil
		end
		return { Gold = Gold }
	end

	local Players = T:Store({ Keys = "Player", Default = Reducers.PLAIN, Reducer = Move })
	local Clans = T:Store({ Keys = "String", Default = Reducers.PLAIN, Reducer = Move, Data = "CaseClan" })

	local Broke, Why = Players.Store
		:Tx("xbroke", {
			{ UserId = 71, Kind = "Move", Fields = { Amount = 25 } },
			{ Store = Clans.Store, Key = "clan x", Kind = "Move", Fields = { Amount = -25 } },
		})
		:Wait()

	Clans.Store:Edit("clan x", "Move", { Amount = 40 }):Wait()
	local Funded = Players.Store
		:Tx("xfunded", {
			{ UserId = 71, Kind = "Move", Fields = { Amount = 25 } },
			{ Store = Clans.Store, Key = "clan x", Kind = "Move", Fields = { Amount = -25 } },
		})
		:Wait()

	T:Is("a transaction the clan cannot afford", Broke, false)
	T:Is("the reason", Why, "Refused")
	T:Is("the same transaction once the clan is funded", Funded, true)
	T:Is("gold on the player", Players:Amount("71"), 25)
	T:Is("gold in the clan", Clans:Amount("clan x"), 15)
end)

Cases.Case("the entity api refuses a nil player", function(T: Case)
	local Store = Plain(T, "String")
	local Nobody: any = nil

	T:Throws("Get", function()
		Store.Store:Get(Nobody)
	end)
	T:Throws("Expect", function()
		Store.Store:Expect(Nobody)
	end)
	T:Throws("IsLoaded", function()
		Store.Store:IsLoaded(Nobody)
	end)
	T:Throws("Read", function()
		Store.Store:Read(Nobody)
	end)
	T:Throws("WaitForLoaded", function()
		Store.Store:WaitForLoaded(Nobody)
	end)
end)

Cases.Case("Edit refuses an unstorable op and an unknown kind", function(T: Case)
	local Store = Plain(T, "String", Adder)

	local Bad, BadWhy = Store.Store:Edit("k", "Add", { Fn = Keep }):Wait()
	local Good, GoodWhy = Store.Store:Edit("k", "Add", { Amount = 1 }):Wait()
	local Unknown, UnknownWhy = Store.Store:Edit("k", "NoSuchKind", { Amount = 1 }):Wait()

	T:Is("an op carrying a function", Bad, false)
	T:Is("the reason", BadWhy, "Invalid")
	T:Is("a good edit", Good, true)
	T:Is("the good reason", GoodWhy, nil)
	T:Is("a kind the reducer does not know", Unknown, false)
	T:Is("the unknown reason", UnknownWhy, "Refused")
end)

Cases.Case("a reset is reconciled against the default", function(T: Case)
	local Store = T:Store({ Default = { Gold = 100, Extra = "keep" }, Reducer = Keep })

	Store:Append("k1", { { Id = "reset1", Kind = "__Reset", State = { Gold = 5 } } :: any })
	local State: any = Store:State("k1")

	T:Is("the field the reset named", State.Gold, 5)
	T:Is("a default field the reset left out", State.Extra, "keep")
end)

Cases.Case("a write settles a pending leg on the way through", function(T: Case)
	local Store = Plain(T, "String", Adder)

	Store:Marker("guardsettle", { Status = "Committed", Total = 1, Gen = "one", Adopted = {} })
	Store:Park("clan", { Id = "tx:guardsettle:1", Kind = "Add", Amount = 25, Tx = "guardsettle" })

	local Before = Store:Amount("clan")
	Store.Store:Edit("clan", "Add", { Amount = 5 }):Wait()

	T:Is("gold while the leg is still pending", Before, 0)
	T:Is("gold once a write settled it", Store:Amount("clan"), 30)
	T:Is("anything left pending", Store:Pending("clan"), false)
end)

Cases.Case("a future can be waited on with a timeout", function(T: Case)
	local Slow = Future.New(function(): number
		task.wait(1)
		return 42
	end)

	local Started = os.clock()
	local TimedOut = Slow:Wait(0.1)
	local Elapsed = os.clock() - Started
	local Running = Slow:Happened()
	local Settled = Slow:Wait()

	T:Is("what a timed out wait hands back", TimedOut, nil)
	T:Is("it returned early", Elapsed < 0.9, true)
	T:Is("the job had not happened yet", Running, false)
	T:Is("the value once it finishes", Settled, 42)
	T:Is("it happened in the end", Slow:Happened(), true)
end)

Cases.Case("a failed future says so rather than returning nothing", function(T: Case)
	local Job = Future.New(function(): number
		error("injected job failure")
	end)
	local Answered = Job:Wait()
	local Happened = Job:Happened()

	T:Is("what a failed job hands back", Answered, nil)
	T:Is("whether it says it happened", Happened, false)
	T:Warns("it named the failure", "Future callback errored")
	T:Warns("it carried the cause", "injected job failure")
end)

Cases.Case("a yielding callback is stopped not just reported", function(T: Case)
	local Reached = { Start = false, Past = false }

	local Ran = pcall(NoYield.Run, function()
		Reached.Start = true
		task.wait(0.05)
		Reached.Past = true
	end)
	task.wait(0.2)

	T:Is("a callback that yields", Ran, false)
	T:Is("it did start", Reached.Start, true)
	T:Is("it got past the yield", Reached.Past, false)
end)

Cases.Case("the retry cap can be lowered while it is retrying", function(T: Case)
	local Limits: { Attempts: number?, Constant: number?, Exponent: number?, Jitter: number? } = { Attempts = 30, Constant = 0.02, Exponent = 1.05 }
	local Tries = 0

	task.delay(0.1, function()
		Limits.Attempts = 2
	end)

	RetryAsync(function()
		Tries += 1
		error("injected failure")
	end, Limits)

	T:Is("it tried at all", Tries > 0, true)
	T:Is("it stopped short of the original cap", Tries < 30, true)
	T:Warns("it said why it gave up", "RetryAsync attempt")
end)

Cases.Case("recovery leaves the overflow for the next pass", function(T: Case)
	local Appends = 0
	local Stub: any = setmetatable({}, {
		__index = function(_, Name: string): any
			return function(_: any, _Key: string, Ops: { any }?): any
				if Name ~= "Append" then
					return { Ops = {}, Seen = {} }
				end
				Appends += 1
				return { Ops = Ops or {}, Seen = {} }
			end
		end,
	})

	local Holds: { [string]: any } = {}
	for Index = 1, 40 do
		Holds[`hold{Index}`] = { To = `to{Index}`, Amount = 1, At = T:Now() }
	end

	local Cleared = Transfer.Recover(Stub, Log.Shape(Adder, { Gold = 0 }), "from", Holds)

	T:Accuses("it noticed the stub never settled a hold", "but the hold on")
	T:Is("recovering more holds than one pass allows", Cleared, false)
	T:Is("how many writes it made, two per hold up to the limit", Appends, 64)
	T:Warns("it said it left some behind", "unfinished transfers")
end)

Cases.Case("a migration that drops a default key is not called out", function(T: Case)
	local function Drop(State: any): any
		local Next = table.clone(State)
		Next.Coins = nil
		return Next
	end

	T:Store({ Default = { Gold = 0, Coins = 0 }, Reducer = Keep, Migrations = { Drop } })
	T:Store({ Default = { Gold = 0 }, Reducer = Keep, Migrations = { Drop } })
	T:Store({
		Default = { Gold = 0 },
		Reducer = Keep,
		Migrations = {
			function(State: any): any
				return { Gold = State.Legacy.Nested }
			end,
		},
	})
	T:Store({
		Default = { Gold = 0, Coins = 0 },
		Reducer = Keep,
		Migrations = {
			Drop,
			function(State: any): any
				local Next = table.clone(State)
				Next.Coins = 100
				return Next
			end,
		},
	})
	T:Store({
		Default = { Gold = 0 },
		Reducer = Keep,
		Migrations = {
			function(State: any): any
				local Next = table.clone(State)
				Next.Gold = State.Coins
				Next.Coins = nil
				return Next
			end,
		},
	})

	T:Silent("nothing complains that the Default still declares a dropped key", "Default still declares")
	T:Holds("New still returns with a yielding migration", function()
		T:Store({
			Default = { Gold = 0 },
			Reducer = Keep,
			Migrations = {
				function(State: any): any
					task.wait(0.2)
					return State
				end,
			},
		})
	end)
end)

Cases.Case("a failed compaction still keeps the write's verdict", function(T: Case)
	local Store = Plain(T, "String", Adder)

	local Bulk: { any } = {}
	for Index = 1, 130 do
		Bulk[Index] = { Id = `seed{Index}`, Kind = "Add", Amount = 1 }
	end
	Store:Append("clancompact", Bulk)

	Store:Fault(Fault.Updates():After(1))
	local Ok, Why = Store.Store:Edit("clancompact", "Add", { Amount = 5 }):Wait()
	Store:Healed()

	T:Is("an edit whose follow up compaction could not be written", Ok, true)
	T:Is("the reason", Why, nil)
end)

Cases.Case("waking a waiter that died is harmless", function(T: Case)
	local Store = Plain(T, "Player")
	local Fake = T:Player(4242)

	local Dead = task.spawn(function()
		Store.Store:WaitForLoaded(Fake)
	end)
	local Woke = false
	task.spawn(function()
		Store.Store:WaitForLoaded(Fake)
		Woke = true
	end)

	coroutine.close(Dead)
	local Threw = not (pcall(function()
		Store.Store:Unload(Fake)
	end))
	task.wait()

	T:Is("unloading while one waiter is dead", Threw, false)
	T:Is("the live waiter still woke", Woke, true)
end)

Cases.Case("erasing a key hands over its holds first", function(T: Case)
	local Store = Purse(T, "CaseErase")

	Store:Append("eraseA", { MakeOp.New("Add", { Amount = 100 }) })
	Store:Append("eraseA", {
		{ Id = "res:fresh", Kind = "__TransferReserve", To = "eraseB", Amount = 40, Tid = "fresh", At = T:Now() } :: any,
	})

	Store.Store:Erase("eraseA"):Wait()

	T:Is("gold handed to the receiver before the key went", Store:Amount("eraseB"), 40)
	T:Is("gold left on the erased key", Store:Amount("eraseA"), 0)
end)

Cases.Case("erasing a key with an undeliverable hold says so", function(T: Case)
	local Store = Purse(T, "CaseEraseMargin")

	Store:Append("marginA", { MakeOp.New("Add", { Amount = 100 }) })
	Store:Append("marginA", {
		{ Id = "res:margin", Kind = "__TransferReserve", To = "marginB", Amount = 40, Tid = "margin", At = T:Now() } :: any,
	})
	T:Advance(7 * 86400 + 43200)

	Store.Store:Erase("marginA"):Wait()

	T:Is("gold to a receiver whose hold is inside the margin", Store:Amount("marginB"), 0)
	T:Is("gold left on the erased key", Store:Amount("marginA"), 0)
	T:Warns("it warned that money went with it", "had not finished")
end)

Cases.Case("the reap works its way round every store when it cannot afford them all at once", function(T: Case)
	local Allowed = 0

	local Names: { string } = {}
	local Found = 0
	local Tried = 0
	while Found < Tx.SHARDS do
		Tried += 1
		local Try = `husk{Tried}`
		local Slot = Tx.Roll.Shard(Try) + 1
		if Names[Slot] == nil then
			Names[Slot] = Try
			Found += 1
		end
	end

	local Stores: { Fixture } = {}
	for Index = 1, 4 do
		local Store = Plain(T, "String", Adder, `CaseRound{Index}`)
		for _, Named in Names do
			Store:Marker(Named, { Status = "Aborted", Total = 1, Gen = "one", Adopted = {} })
		end
		Store:MarkerBudget(function(Kind: Enum.DataStoreRequestType): number
			if Kind ~= Enum.DataStoreRequestType.ListAsync then
				return 1000
			end
			Allowed -= 1
			return if Allowed >= 0 then 1000 else 0
		end)
		Stores[Index] = Store
	end

	T:Advance(Tx.REAP_HORIZON + 60)

	local function Left(): number
		local Standing = 0
		for _, Store in Stores do
			if #Store:Marks() == Tx.SHARDS then
				Standing += 1
			end
		end
		return Standing
	end

	T:Is("every store starts with husks to reap", Left(), 4)

	for _ = 1, 10 do
		Allowed = 2
		T:Sweep()
	end
	local AfterOne = Left()

	for _ = 1, 10 do
		Allowed = 2
		T:Sweep()
	end

	T:Is("a budget for two only reaps two", AfterOne, 2)
	T:Is("the second pass reaches the two it skipped", Left(), 0)
end)

Cases.Case("the sweep settles a leg nobody else will", function(T: Case)
	local Store = Plain(T, "String", Adder, "CaseSweep")

	Store:Marker("sweeptx", { Status = "Committed", Total = 1, Gen = "one", Adopted = {} })
	Store:Park("swept", { Id = "tx:sweeptx:1", Kind = "Add", Amount = 40, Tx = "sweeptx" })

	local Stale = Store:Amount("swept")
	Store.Store:Peek("swept"):Wait()
	T:Sweep()

	T:Is("gold while the leg is stranded", Stale, 0)
	T:Is("gold once the sweep settled it", Store:Amount("swept"), 40)
	T:Is("anything left pending", Store:Pending("swept"), false)
end)

Cases.Case("the sweep gives up on a leg it can never settle", function(T: Case)
	local Store = Plain(T, "String", Adder, "CaseStuck")
	local Reads = 0

	Store:Park("stuck", { Id = "tx:ghost:1", Kind = "Add", Amount = 1, Tx = "ghost", TxHome = "\0nowhere" })
	Store.Store:Peek("stuck"):Wait()

	Store:Fault(Fault.Reads():Meddle(function()
		Reads += 1
	end))

	for _ = 1, 12 do
		T:Sweep()
	end
	Store:Healed()

	T:Is("the sweep tried at all", Reads > 0, true)
	T:Is("it stopped rather than retrying forever", Reads <= 5, true)
end)

Cases.Case("the sweep finishes an escrow left in flight", function(T: Case)
	local Store = Purse(T, "CaseEscrowSweep")
	Store.Store:Edit("flightA", "Add", { Amount = 100 }):Wait()

	Store:Fault(Fault.Updates():After(1))
	local Ok, Why = Store.Store:Transfer("flightA", "flightB", 40):Wait()
	Store:Healed()

	T:Is("a transfer that could not hand the money over", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("gold left to the sender", Store:Amount("flightA"), 60)
	T:Is("gold on the receiver before the sweep", Store:Amount("flightB"), 0)

	T:Sweep()

	T:Is("gold on the receiver once the sweep finished it", Store:Amount("flightB"), 40)
	T:Is("gold on the sender", Store:Amount("flightA"), 60)
	T:Is("anything still set aside", Store:Aside("flightA"), 0)
end)

Cases.Case("reading a key schedules its stranded escrow", function(T: Case)
	local Store = Purse(T, "CasePeekHeld")

	Store:Append("peekA", { MakeOp.New("Add", { Amount = 100 }) })
	Store:Append("peekA", {
		{ Id = "res:stranded", Kind = "__TransferReserve", To = "peekB", Amount = 40, Tid = "stranded", At = T:Now() } :: any,
	})

	T:Sweep()
	T:Is("gold on the receiver before anyone reads the sender", Store:Amount("peekB"), 0)

	Store.Store:Peek("peekA"):Wait()
	T:Sweep()

	T:Is("gold on the receiver once a read scheduled the sweep", Store:Amount("peekB"), 40)
	T:Is("anything still set aside", Store:Aside("peekA"), 0)
end)

Cases.Case("asking what a key has applied schedules its stranded escrow too", function(T: Case)
	local Store = Purse(T, "CaseAskHeld")

	Store:Append("askA", { MakeOp.New("Add", { Amount = 100 }) })
	Store:Append("askA", {
		{ Id = "res:stranded", Kind = "__TransferReserve", To = "askB", Amount = 40, Tid = "stranded", At = T:Now() } :: any,
	})

	T:Sweep()
	T:Is("gold on the receiver before anyone asks about the sender", Store:Amount("askB"), 0)

	Store.Store:DidApply("askA", "anything"):Wait()
	T:Sweep()

	T:Is("gold on the receiver once the question scheduled the sweep", Store:Amount("askB"), 40)
	T:Is("anything still set aside", Store:Aside("askA"), 0)
end)

Cases.Case("the sweep keeps going while it is still clearing holds", function(T: Case)
	local Store = Purse(T, "CaseManyHolds")
	local Stranded = 200

	Store:Append("bulkA", { MakeOp.New("Add", { Amount = Stranded }) })

	local Batch: { any } = {}
	for Index = 1, Stranded do
		table.insert(Batch, {
			Id = `res:bulk{Index}`,
			Kind = "__TransferReserve",
			To = "bulkB",
			Amount = 1,
			Tid = `bulk{Index}`,
			At = T:Now(),
		})
	end
	Store:Append("bulkA", Batch)

	Store.Store:Peek("bulkA"):Wait()
	for _ = 1, 12 do
		T:Sweep()
	end

	T:Is("holds cleared when there are more than one pass can take", Store:Aside("bulkA"), 0)
	T:Is("gold on the receiver", Store:Amount("bulkB"), Stranded)
end)

Cases.Case("a reducer that writes into the state it was given is refused on every path", function(T: Case)
	local Store = T:Store({
		Default = { Gold = 10 },
		Data = "CaseMutatingReducer",
		Reducer = function(State: any, Op: any): any?
			if Op.Kind == "Sneak" then
				State.Gold = 999
				return table.clone(State)
			end
			if Op.Kind == "Add" then
				local Next = table.clone(State)
				Next.Gold += 1
				return Next
			end
			return nil
		end,
	})

	Store.Store:Edit("k", "Add"):Wait()

	local Ok, Why = Store.Store:Edit("k", "Sneak"):Wait()
	T:Is("an edit whose reducer wrote into the state it was handed", Ok, false)
	T:Is("the reason it gives", Why, "Refused")
	T:Is("gold after the reducer tried to write into live state", Store:Amount("k"), 11)
end)

Cases.Case("a reducer cannot clear the applied names on a store with no balance", function(T: Case)
	local Store = T:Store({
		Default = Reducers.PLAIN,
		Data = "CaseWipeReceived",
		Reducer = function(State: any, Op: any): any?
			if Op.Kind == "Add" then
				local Next = table.clone(State)
				Next.Gold = (Next.Gold or 0) + 1
				return Next
			end
			if Op.Kind == "Wipe" then
				local Next = table.clone(State)
				Next._Received = {}
				return Next
			end
			return nil
		end,
	})

	Store.Store:Edit("k", "Add", { Once = "keepme" }):Wait()
	Store.Store:Edit("k", "Wipe"):Wait()

	T:Accuses("it named itself for a mistake the reducer made", "your reducer wrote its own _Received")
	T:Is("the name a reducer tried to forget", Store.Store:DidApply("k", "keepme"):Wait(), true)
	T:Is("replaying it after the reducer tried to clear the set", Store.Store:Edit("k", "Add", { Once = "keepme" }):Wait(), false)
	T:Is("gold after the replay", Store:Amount("k"), 1)
end)

Cases.Case("a reset uses the default the store was built with", function(T: Case)
	local Default = { Gold = 100 }
	local Store = T:Store({ Default = Default, Reducer = Adder, Data = "CaseResetDefault" })

	Store.Store:Edit("k", "Add", { Amount = 5 }):Wait()
	Default.Gold = 7777
	Store.Store:Reset("k"):Wait()

	T:Is("gold a reset goes back to", Store:Amount("k"), 100)
	T:Is("gold a key nobody wrote folds to", Store:Amount("fresh"), 100)
end)

Cases.Case("the disk keeps the reason a record from a newer build raises", function(T: Case)
	local Store = Plain(T, "String", Adder, "CaseMockBehind")

	Store:Write("newer", { Snapshot = { Gold = 5 }, Ops = {}, Seen = {}, Envelope = 999 })

	local Read, ReadWhy = Store.Store:Peek("newer"):Wait()
	T:Is("reading a record from a newer build", Read, nil)
	T:Is("the reason reading gives", ReadWhy, "Behind")

	local Reset, ResetWhy = Store.Store:Reset("newer"):Wait()
	T:Is("resetting a record from a newer build", Reset, false)
	T:Is("the reason resetting gives", ResetWhy, "Behind")
end)

Cases.Case("RecoverTransfers says so when it ran out of room", function(T: Case)
	local Store = Purse(T, "CaseRecoverPartial")
	local Stranded = 40

	Store:Append("partA", { MakeOp.New("Add", { Amount = Stranded }) })

	local Batch: { any } = {}
	for Index = 1, Stranded do
		table.insert(Batch, {
			Id = `res:part{Index}`,
			Kind = "__TransferReserve",
			To = "partB",
			Amount = 1,
			Tid = `part{Index}`,
			At = T:Now(),
		})
	end
	Store:Append("partA", Batch)

	local First, Why = Store.Store:RecoverTransfers("partA"):Wait()
	T:Is("a pass that could not take every hold", First, false)
	T:Is("the reason it gives", Why, "Busy")

	local Second = Store.Store:RecoverTransfers("partA"):Wait()
	T:Is("the pass that finishes the rest", Second, true)
	T:Is("anything still set aside", Store:Aside("partA"), 0)
end)

Cases.Case("a reset is refused against a record from a newer format", function(T: Case)
	local Store = T:Store({
		Default = Reducers.PLAIN,
		Reducer = Keep,
		Data = "CaseResetVer",
		Migrations = {
			function(State: any): any
				return State
			end,
		},
	})

	Store:Write("ahead", { Snapshot = { Gold = 500 }, Ops = {}, Seen = {}, Version = 4, Floor = 4, Envelope = 1 })

	local Ok, Why = Store.Store:Reset("ahead"):Wait()
	local After = Store:Record("ahead")

	T:Is("resetting a record a newer server wrote", Ok, false)
	T:Is("the reason names the build gap, not a reducer saying no", Why, "Behind")
	T:Is("the stored version is untouched", After.Version, 4)
	T:Is("ops it left behind", #After.Ops, 0)

	Store:Write("behind", { Snapshot = { Gold = 500 }, Ops = {}, Seen = {}, Version = 1, Floor = 1, Envelope = 1 })

	T:Is("resetting a record this server understands", Store.Store:Reset("behind"):Wait(), true)
end)

Cases.Case("a peek of a record a newer framework wrote says behind", function(T: Case)
	local Store = Plain(T, "String", nil, "CaseEnvelope")

	Store:Write("newer", { Snapshot = { Gold = 10 }, Ops = {}, Seen = {}, Envelope = 99 })

	local State, Why = Store.Store:Peek("newer"):Wait()

	T:Is("a record whose envelope this server does not know", State, nil)
	T:Is("the reason", Why, "Behind")
end)

Cases.Case("a peek of a record needing a migration this server lacks says behind", function(T: Case)
	local Store = Plain(T, "String", nil, "CaseAheadPeek")

	Store:Write("ahead", { Snapshot = { Gold = 10 }, Ops = {}, Seen = {}, Version = 4, Floor = 4, Envelope = 1 })

	local State, Why = Store.Store:Peek("ahead"):Wait()

	T:Is("a record needing a migration this server does not have", State, nil)
	T:Is("the reason", Why, "Behind")
end)

Cases.Case("a peek of a forward compatible record is not behind", function(T: Case)
	local Store = Plain(T, "String", nil, "CaseCompatPeek")

	Store:Write("additive", { Snapshot = { Gold = 10, Pets = {} }, Ops = {}, Seen = {}, Version = 4, Floor = 0, Envelope = 1 })

	local State, Why = Store.Store:Peek("additive"):Wait()

	T:Is("a record a newer server wrote additively still reads", (State :: any).Gold, 10)
	T:Is("the reason", Why, nil)
end)

Cases.Case("a peek that cannot reach the datastore says unresolved", function(T: Case)
	local Store = Plain(T, "String", nil, "CaseDownPeek")

	Store:Fault(Fault.Reads())
	local State, Why = Store.Store:Peek("gone"):Wait()
	Store:Healed()

	T:Is("a read the datastore never answered", State, nil)
	T:Is("the reason", Why, "Unresolved")
end)

Cases.Case("a peek of a key nobody wrote is the default", function(T: Case)
	local Store = Plain(T, "String", nil, "CaseFreshPeek")

	local State, Why = Store.Store:Peek("untouched"):Wait()

	T:Is("a key nobody has written folds to the default", (State :: any).Gold, 0)
	T:Is("the reason", Why, nil)
	T:Is("nothing means the read failed, so it is never the answer for a fresh key", State ~= nil, true)
end)

Cases.Case("a history that cannot be listed says unresolved", function(T: Case)
	local Store = Plain(T, "String", nil, "CaseDownHistory")

	Store:Fault(Fault.On("ListVersionsAsync"))
	local Rows, Why = Store.Store:History("gone"):Wait()
	Store:Healed()

	T:Is("a history the datastore never listed", Rows, nil)
	T:Is("the reason", Why, "Unresolved")
end)

Cases.Case("an erase that cannot be written says so and keeps the record", function(T: Case)
	local Store = Plain(T, "String", Adder, "CaseDownErase")

	Store.Store:Edit("kept", "Add", { Amount = 10 }):Wait()

	Store:Fault(Fault.Updates())
	local Ok, Why = Store.Store:Erase("kept"):Wait()
	Store:Healed()

	T:Is("an erase the datastore never took", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("the record it could not erase is still there", Store:Amount("kept"), 10)
end)

Cases.Case("an edit onto a record a newer server wrote says behind", function(T: Case)
	local Store = Plain(T, "String", Adder, "CaseEditBehind")

	Store:Write("newer", { Snapshot = { Gold = 10 }, Ops = {}, Seen = {}, Envelope = 99 })

	local Ok, Why = Store.Store:Edit("newer", "Add", { Amount = 5 }):Wait()

	T:Is("writing onto a record this server cannot read", Ok, false)
	T:Is("the reason", Why, "Behind")
end)

Cases.Case("an edit onto a record this server cannot read is refused before it lands", function(T: Case)
	local Store = Plain(T, "String", Adder, "CaseLandedThenLost")

	Store:Write("ahead", { Snapshot = { Gold = 10 }, Ops = {}, Seen = {}, Version = 4, Floor = 4, Envelope = 1 })

	local Ok, Why = Store.Store:Edit("ahead", "Add", { Amount = 5 }):Wait()

	T:Is("an edit onto a record written by a newer build", Ok, false)
	T:Is("ops reaching the log, since Behind promises nothing was written", #Store:Record("ahead").Ops, 0)
	T:Is("the reason", Why, "Behind")
end)

Cases.Case("a peek version that cannot be read says unresolved", function(T: Case)
	local Store = Plain(T, "String", Adder, "CaseDownVersion")

	Store.Store:Edit("versioned", "Add", { Amount = 5 }):Wait()

	Store:Fault(Fault.Versions())
	local State, Why = Store.Store:PeekVersion("versioned", "1"):Wait()
	Store:Healed()

	T:Is("a version the datastore never handed back", State, nil)
	T:Is("the reason", Why, "Unresolved")
end)

Cases.Case("a recovery that cannot read the key says unresolved", function(T: Case)
	local Store = Purse(T, "CaseDownRecover")

	T:Is("recovering a key with nothing set aside", Store.Store:RecoverTransfers("purse"):Wait(), true)

	Store:Fault(Fault.Reads())
	local Ok, Why = Store.Store:RecoverTransfers("purse"):Wait()
	Store:Healed()

	T:Is("the same call once the key cannot be read", Ok, false)
	T:Is("the reason", Why, "Unresolved")
end)

Cases.Case("a DidApply that cannot read says so rather than not applied", function(T: Case)
	local Store = Plain(T, "String", Adder, "CaseDidApply")

	Store.Store:Edit("named", "Add", { Amount = 5, Once = "grant:1" }):Wait()
	T:Is("a name that did apply", Store.Store:DidApply("named", "grant:1"):Wait(), true)
	T:Is("a name that never applied", Store.Store:DidApply("named", "grant:2"):Wait(), false)

	Store:Fault(Fault.Reads())
	local Applied, Why = Store.Store:DidApply("named", "grant:1"):Wait()
	Store:Healed()

	T:Is("a name it could not go and check is never a plain no", Applied, nil)
	T:Is("the reason", Why, "Unresolved")
end)

Cases.Case("a transfer out of a record a newer server wrote says behind", function(T: Case)
	local Store = Purse(T, "CasePurseBehind")

	Store:Write("payer", { Snapshot = { Gold = 100 }, Ops = {}, Seen = {}, Envelope = 99 })

	local Ok, Why = Store.Store:Transfer("payer", "payee", 25):Wait()

	T:Is("moving money out of a record this server cannot read", Ok, false)
	T:Is("the reason", Why, "Behind")
end)

Cases.Case("a maintenance call says whether it ran", function(T: Case)
	local Store = Plain(T, "String", nil, "CaseTidy")

	T:Is("clearing the delivered transfers on a key", Store.Store:ClearDelivered("tidy"):Wait(), true)

	Store:Fault(Fault.Updates())
	local Ok, Why = Store.Store:ClearDelivered("tidy"):Wait()
	Store:Healed()

	T:Is("the same call once the datastore stops answering", Ok, false)
	T:Is("the reason", Why, "Unresolved")
end)

Cases.Case("a guarded callback hands back every value it returned", function(T: Case)
	local First, Second, Third = NoYield.Run(function(A: number, B: number)
		return A + B, "two", nil
	end, 1, 2)

	T:Is("the first value", First, 3)
	T:Is("the second value", Second, "two")
	T:Is("the third value", Third, nil)
end)

Cases.Case("a guarded callback keeps the reason on a fault it raised", function(T: Case)
	local Ran, Raised = pcall(NoYield.Run, function()
		error(Broke.New("Busy", "a leg is parked"))
	end)

	T:Is("a callback that raised a fault", Ran, false)
	T:Is("the reason it carried", Broke.Of(Raised), "Busy")
end)

Cases.Case("a guarded callback can guard another one inside itself", function(T: Case)
	local Inner = NoYield.Run(function(): string
		return NoYield.Run(function(): string
			return "inner"
		end)
	end)

	local Ran = pcall(NoYield.Run, function()
		return NoYield.Run(function()
			task.wait(0.05)
		end)
	end)
	task.wait(0.2)

	T:Is("a guarded call inside a guarded call", Inner, "inner")
	T:Is("one that yields two deep", Ran, false)
	T:Is(
		"a plain call once the nested one was stopped",
		NoYield.Run(function(): number
			return 7
		end),
		7
	)
end)

Cases.Case("a thread that threw is not handed out again", function(T: Case)
	for _ = 1, 8 do
		pcall(NoYield.Run, function()
			error("thrown")
		end)
		pcall(NoYield.Run, function()
			task.wait(0.02)
		end)
	end
	task.wait(0.2)

	local Reached = false
	local Value = NoYield.Run(function(A: number): number
		Reached = true
		return A * 2
	end, 21)

	T:Is("a call after threads threw and yielded", Value, 42)
	T:Is("the callback ran", Reached, true)
end)

local function Blinded(T: Case, Data: string): Fixture
	return T:Store({
		Default = Reducers.PLAIN,
		Reducer = Adder,
		Data = Data,
		Migrations = {
			function(_State: any): any
				error("this build cannot migrate that record")
			end,
		},
	})
end

Cases.Case("an erase that cannot read back what went with it says so", function(T: Case)
	local Store = Blinded(T, "CaseEraseBlind")
	Store:Write("blind", { Snapshot = { Gold = 40 }, Ops = {}, Seen = {}, Version = 0, Floor = 0 })

	local Ok = Store.Store:Erase("blind"):Wait()

	T:Is("the erase itself", Ok, true)
	T:Warns("it said it could not say what went with it", "but could not read back what was on it")
	T:Is("the key was entombed anyway", Store:Record("blind").Erased ~= nil, true)
end)

Cases.Case("a write it cannot read back is unresolved rather than landed", function(T: Case)
	local Store = Blinded(T, "CaseWriteBlind")
	Store:Write("blind", { Snapshot = { Gold = 5 }, Ops = {}, Seen = {}, Version = 0, Floor = 0 })

	local Ok, Why = Store.Store:Edit("blind", "Add", { Amount = 1 }):Wait()

	T:Is("the write", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Warns("it said it could not read the record back", "could not read the record back to say what it folded to")
	T:Is("the op is in the log even so", #Store:Record("blind").Ops, 1)
end)

Cases.Case("an erase that cannot check its holds a second time says the money is gone", function(T: Case)
	local Store = Purse(T, "CaseEraseRecheck")

	Store:Append("recheck", { MakeOp.New("Add", { Amount = 100 }) })
	Store:Append("recheck", {
		{ Id = "res:recheck", Kind = "__TransferReserve", To = "elsewhere", Amount = 40, Tid = "recheck", At = T:Now() } :: any,
	})

	Store:NoRetries()
	Store:Fault(Fault.Reads():OnKey("recheck"):After(1))
	Store.Store:Erase("recheck"):Wait()
	Store:Healed()

	T:Warns("it said it could not look again", "again after finishing its transfers")
end)

return Cases
