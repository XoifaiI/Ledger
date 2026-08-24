--!strict
--!optimize 2

--[=[
	Live: One rule per case for a live session.

	Apply is hopeful and answers at once. Commit is durable before it answers. Everything here follows
	from that split.
	The fence is the other half: a session that loaded before an erase must not write a dead profile
	back, and one that loaded after writes normally. The last group is about loading a player, which
	can fail, be asked for twice, or be cancelled while it runs.

	Return type: The case file.
	Example usage:
		Add a case with Cases.Case, and it runs the next time you press play.
--]=]

local Suite = require("../Suite")

local Fault = Suite.Fault
local Insides = Suite.Insides
local Reducers = Suite.Reducers

local Ledger = Insides.Ledger
local MakeOp = Insides.MakeOp
local Observer = Insides.Observer
local Registry = Insides.Registry
local Session = Insides.Session

type Case = Suite.Case
type Fixture = Suite.Fixture

local Cases = Suite.File("Live")

local function Outside(Bank: Fixture, Key: string, Kind: string, Fields: { [any]: any }?)
	Bank:Append(Key, { MakeOp.New(Kind, Fields) })
end

local function Filler(Count: number): { number }
	local Pad: { number } = table.create(Count, 0)
	for Index = 1, Count do
		Pad[Index] = Index
	end
	return Pad
end

local function Bag(Count: number): { [string]: any }
	local Items: { [string]: any } = {}
	for Index = 1, Count do
		Items[`item{Index}`] = { Count = Index, Tag = "probe" }
	end
	return Items
end

local function Ticker(State: any, Op: any): any?
	if Op.Kind ~= "Tick" then
		return nil
	end
	local Next = table.clone(State)
	Next.Gold += 1
	return Next
end

local function Failing(T: Case, UserId: number, Answer: any): (Fixture, any, { any })
	local Seen: { any } = {}
	local Store = T:Store({
		Keys = "Player",
		Default = Reducers.PLAIN,
		Reducer = Reducers.Keep,
		OnLoadFailed = function(Player: any, Why: any): boolean
			table.insert(Seen, { Player = Player, Why = Why })
			return Answer(Player, Why)
		end
	})
	return Store, T:Player(UserId), Seen
end

local function Broke(Store: Fixture, Body: () -> ())
	Store:Fault(Fault.Reads())
	Body()
	Store:Healed()
end

Cases.Case("an apply whose verdict hangs on a stuck leg is refused", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("hungApply", { Gold = 100 })
	Bank:Marker("hungapply1", { Status = "Pending", Total = 2, Adopted = {} })
	Bank:Park("hungApply", { Id = "tx:hungapply1:1", Kind = "Give", Amount = -30, Tx = "hungapply1" })

	local Active = Bank:Session("hungApply")
	T:Is("gold the session reads with the leg skipped", Active:Get().Gold, 100)

	local Ok, Why = Active:Apply("Give", { Amount = -80 })

	T:Is("an apply the parked leg would overturn", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("gold the session reports", Active:Get().Gold, 100)
	T:Is("anything queued", #Active.Pending, 0)
end)

Cases.Case("an apply the leg cannot overturn stays accepted", function(T: Case)
	local Bank = T:Bank()

	Bank:Seed("sureApply", { Gold = 100 })
	Bank:Marker("sureapply1", { Status = "Pending", Total = 2, Adopted = {} })
	Bank:Park("sureApply", { Id = "tx:sureapply1:1", Kind = "Give", Amount = -30, Tx = "sureapply1" })

	local Active = Bank:Session("sureApply")
	local Ok, Why = Active:Apply("Fund", { Amount = 5 })

	T:Is("an apply the parked leg cannot overturn", Ok, true)
	T:Is("the reason", Why, nil)
	T:Is("gold the session reports", Active:Get().Gold, 105)
	T:Is("it is queued for the next save", #Active.Pending, 1)
end)

Cases.Case("an apply is refused while two transactions are parked", function(T: Case)
	local Shop = T:Market()

	Shop:Seed("twoparked", { Gold = 100, Items = { Sword = true } })
	Shop:Marker("parkedA", { Status = "Pending", Total = 2, Gen = "ga", At = T:Now(), Adopted = {} })
	Shop:Marker("parkedB", { Status = "Pending", Total = 2, Gen = "gb", At = T:Now(), Adopted = {} })
	Shop:Park("twoparked", { Id = "tx:parkedA:1", Kind = "Delta", Drop = "Sword", Tx = "parkedA", TxGen = "ga", TxAt = T:Now() })
	Shop:Park("twoparked", { Id = "tx:parkedB:1", Kind = "Delta", Gain = "Sword", Tx = "parkedB", TxGen = "gb", TxAt = T:Now() })

	local Active: any = Shop:Session("twoparked")
	local Stored = Shop:Record("twoparked")

	local Ok, Why = Active:Apply("Delta", { Drop = "Sword" })
	local _, Sure = Shop:Format():Certain(Stored, "tx:parkedA:1")

	T:Is("the transactions the session counts as parked", Active.Parked, 2)
	T:Is("the shadow state, which cannot speak for two", Active.Landed, nil)
	T:Is("an apply that only holds if both settle the same way", Ok, false)
	T:Is("the reason", Why, "Unresolved")
	T:Is("the durable path agrees it cannot be sure", Sure, false)
	T:Is("nothing was queued", #Active.Pending, 0)
end)

Cases.Case("a session that loaded before an erase cannot write through it", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("fenced", { Gold = 100 })

	local Active = Bank:Session("fenced")
	Active:Apply("Fund", { Amount = 5 })

	Bank.Store:Erase("fenced"):Wait()
	Active:Flush():Wait()

	local Record = Bank:Record("fenced")

	T:Is("ops the erased key took from the older session", #Record.Ops, 0)
	T:Is("the tombstone", Record.Erased ~= nil, true)
	T:Is("the session, which cannot write any more", Active.Released, true)
	T:Warns("it says why", "was erased while this session was live", 1)
	T:Is("an apply after that", (Active:Apply("Fund", { Amount = 1 })), false)
end)

Cases.Case("a final save the fence stopped does not report success", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("lastsave", { Gold = 100 })

	local Active = Bank:Session("lastsave")
	Active:Apply("Fund", { Amount = 5 })
	Bank.Store:Erase("lastsave"):Wait()

	local Flushed, FlushWhy = Active:Flush():Wait()
	local Saved, SaveWhy = Active:Release():Wait()

	T:Is("a flush the fence stopped", Flushed, false)
	T:Is("the reason a flush gives", FlushWhy, "Refused")
	T:Is("a final save the fence stopped", Saved, false)
	T:Is("the reason a final save gives", SaveWhy, "Refused")
	T:Is("ops on the erased key", #Bank:Record("lastsave").Ops, 0)
end)

Cases.Case("Commit cannot write through the fence either", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("commitfence", { Gold = 100 })

	local Active = Bank:Session("commitfence")
	Bank.Store:Erase("commitfence"):Wait()

	local Ok, Why = Active:Commit("Fund", { Amount = 5 }):Wait()
	local Record = Bank:Record("commitfence")

	T:Is("a commit onto a key erased under the session", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("ops on the erased key", #Record.Ops, 0)
	T:Is("the tombstone", Record.Erased ~= nil, true)
end)

Cases.Case("a session that loaded after an erase writes normally", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("afterwards", { Gold = 100 })

	Bank.Store:Erase("afterwards"):Wait()
	local Active = Bank:Session("afterwards")
	Active:Apply("Fund", { Amount = 7 })
	Active:Flush():Wait()

	T:Is("gold the fresh session folds", Active:Get().Gold, 7)
	T:Is("gold on disk", Bank:Amount("afterwards"), 7)
	T:Is("the session, still live", Active.Released, false)
	T:Is("the tombstone, which the write did not cancel", Bank:Record("afterwards").Erased ~= nil, true)
end)

Cases.Case("flushing the same ops again applies them once", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("onceK", { Gold = 0 })

	local Active = Bank:Session("onceK")
	Outside(Bank, "onceK", "Fund", { Amount = 50 })
	Active:Flush():Wait()
	Active:Flush():Wait()
	Active:Flush():Wait()

	T:Is("gold the session reports after three flushes", Active:Get().Gold, 50)
	T:Is("gold on disk", Bank:Amount("onceK"), 50)
end)

Cases.Case("every apply accepted during a flush still lands", function(T: Case)
	T:Slow()

	local Bank = T:Bank()
	Bank:Seed("flushK", { Gold = 0 })

	local Active = Bank:Session("flushK")
	local Applied = 0
	local Flushing = true

	task.spawn(function()
		while Flushing do
			Active:Flush():Wait()
		end
	end)
	for _ = 1, 40 do
		if Active:Apply("Fund", { Amount = 1 }) then
			Applied += 1
		end
		task.wait()
	end
	Flushing = false
	Active:Flush():Wait()

	T:Is("every apply was accepted", Applied, 40)
	T:Is("gold on disk", Bank:Amount("flushK"), Applied)
	T:Is("gold the session reports", Active:Get().Gold, Applied)
end)

Cases.Case("applies never flushed are lost on reload", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("crashK", { Gold = 0 })

	local First = Bank:Session("crashK")
	for _ = 1, 5 do
		First:Apply("Fund", { Amount = 10 })
	end
	First:Flush():Wait()
	local Saved = First:Get().Gold
	for _ = 1, 3 do
		First:Apply("Fund", { Amount = 10 })
	end

	local Second = Bank:Session("crashK")

	T:Is("gold flushed before the crash", Saved, 50)
	T:Is("gold a fresh session loads", Second:Get().Gold, 50)
end)

Cases.Case("two sessions spending the same gold never go negative", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("splitK", { Gold = 100 })

	local Left, Right = Bank:Session("splitK"), Bank:Session("splitK")
	Left:Apply("Give", { Amount = -100 })
	Right:Apply("Give", { Amount = -100 })
	Left:Flush():Wait()
	Right:Flush():Wait()

	T:Is("gold on disk once both optimistic spends are flushed", Bank:Amount("splitK"), 0)
end)

Cases.Case("only one of two racing commits wins", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("commitK", { Gold = 100 })

	local Left, Right = Bank:Session("commitK"), Bank:Session("commitK")
	local Won, Lost = false, false

	T:Race({
		function()
			Won = Left:Commit("Give", { Amount = -100 }):Wait()
		end,
		function()
			Lost = Right:Commit("Give", { Amount = -100 }):Wait()
		end
	})

	local Accepted = (if Won then 1 else 0) + (if Lost then 1 else 0)

	T:Is("how many of the two racing commits were accepted", Accepted, 1)
	T:Is("gold on disk", Bank:Amount("commitK"), 0)
end)

Cases.Case("an outside edit is not seen until the session flushes", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("basketK", { Gold = 0 })

	local Active = Bank:Session("basketK")
	Outside(Bank, "basketK", "Fund", { Amount = 250 })
	local Before = Active:Get().Gold

	Active:Flush():Wait()

	T:Is("gold before the flush", Before, 0)
	T:Is("gold after the flush", Active:Get().Gold, 250)
end)

Cases.Case("edits made while offline are folded on load", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("offlineK", { Gold = 0 })

	Outside(Bank, "offlineK", "Fund", { Amount = 30 })
	Outside(Bank, "offlineK", "Fund", { Amount = 20 })
	local Active = Bank:Session("offlineK")

	T:Is("gold a session loads", Active:Get().Gold, 50)
end)

Cases.Case("an apply during a flush is kept", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("overlayK", { Gold = 100 })

	local Active = Bank:Session("overlayK")
	local Flushing = Active:Flush()
	local Applied = Active:Apply("Fund", { Amount = 10 })
	Flushing:Wait()

	T:Is("the apply landing mid flush", Applied, true)
	T:Is("gold the session reports", Active:Get().Gold, 110)
end)

Cases.Case("a released session refuses everything", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("releasedK", { Gold = 100 })

	local Active = Bank:Session("releasedK")
	Active:Release():Wait()

	local Applied, AppliedWhy = Active:Apply("Fund", { Amount = 50 })
	local Committed, CommittedWhy = Active:Commit("Fund", { Amount = 50 }):Wait()

	T:Is("applying to a released session", Applied, false)
	T:Is("the reason an apply gives", AppliedWhy, "Closed")
	T:Is("committing to a released session", Committed, false)
	T:Is("the reason a commit gives", CommittedWhy, "Closed")
	T:Is("gold on disk", Bank:Amount("releasedK"), 100)
	T:Is("gold the session still reports", Active:Get().Gold, 100)
end)

Cases.Case("a yielding reducer is skipped not stored", function(T: Case)
	local function Yieldy(State: any, Op: any): any?
		if Op.Kind == "Yieldy" then
			task.wait()
			return { Gold = State.Gold + Op.Amount, Touches = State.Touches }
		end
		if Op.Kind ~= "Fund" then
			return nil
		end
		return { Gold = State.Gold + Op.Amount, Touches = State.Touches }
	end

	local Bank = T:Store({ Default = Reducers.MONEY, Reducer = Yieldy, Balance = "Gold" })
	Bank:Seed("yieldyK", { Gold = 100 })

	local Active = Bank:Session("yieldyK")
	local Threw = not (pcall(function()
		Active:Apply("Yieldy", { Amount = 50 })
	end))

	Outside(Bank, "yieldyK", "Yieldy", { Amount = 50 })
	Active:Flush():Wait()
	local Folded = Active:Get().Gold

	local Packing = Active:Compact()
	Packing:Wait()

	T:Is("applying an op whose reducer yields", Threw, true)
	T:Is("gold once a yielding op is folded", Folded, 100)
	T:Is("compaction still finished", Packing:Happened(), true)
	T:Is("gold on disk after compaction", Bank:Amount("yieldyK"), 100)
end)

Cases.Case("a reducer that gives back the state it was handed takes the op", function(T: Case)
	local function Keeper(State: any, Op: any): any?
		if Op.Kind ~= "Same" then
			return nil
		end
		return State
	end

	local Bank = T:Store({ Default = Reducers.MONEY, Reducer = Keeper, Balance = "Gold" })
	Bank:Seed("sameK", { Gold = 100 })

	local Active = Bank:Session("sameK")
	local Gave = false
	local Raised = not (pcall(function()
		Gave = (Active:Apply("Same", {}))
	end))
	Active:Flush():Wait()

	T:No("applying an op the reducer changes nothing for, which must not raise", Raised)
	T:Ok("it takes the op", Gave)
	T:Is("gold, which the op does not move", Active:Get().Gold, 100)
	T:Is("ops the key took", #Bank:Record("sameK").Ops, 1)
	T:Is("gold a fresh fold reads", Bank:Amount("sameK"), 100)
end)

Cases.Case("a reducer that throws refuses the op rather than the call", function(T: Case)
	local function Thrower(State: any, Op: any): any?
		if Op.Kind == "Bang" then
			error("the reducer blew up")
		end
		if Op.Kind ~= "Fund" then
			return nil
		end
		return { Gold = State.Gold + Op.Amount, Touches = State.Touches }
	end

	local Bank = T:Store({ Default = Reducers.MONEY, Reducer = Thrower, Balance = "Gold" })
	Bank:Seed("bangK", { Gold = 100 })

	local Active = Bank:Session("bangK")
	local Gave = true
	local Reason = ""
	local Raised = not (pcall(function()
		local Held, Why = Active:Apply("Bang", {})
		Gave = Held
		Reason = tostring(Why)
	end))

	Outside(Bank, "bangK", "Bang", {})
	Active:Flush():Wait()

	T:No("applying an op whose reducer throws, which must not raise", Raised)
	T:No("what it answers", Gave)
	T:Ok("the reason is the one a fold gives the same op", Reason == "Refused")
	T:Warns("it says the reducer threw", "your reducer threw", 1)
	T:Is("gold once a throwing op is folded", Active:Get().Gold, 100)
	T:Is("gold on disk", Bank:Amount("bangK"), 100)
end)

Cases.Case("a session refuses Ledger's own kinds", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("reservedK", { Gold = 100 })

	local Active = Bank:Session("reservedK")
	local Applied = Active:Apply("__TransferDeliver", { Tid = "forge", Amount = 1000000 })
	local Committed = Active:Commit("__TransferDeliver", { Tid = "forge2", Amount = 1000000 }):Wait()
	Active:Flush():Wait()

	T:Is("applying an op under a kind Ledger owns", Applied, false)
	T:Is("committing one", Committed, false)
	T:Is("gold on disk", Bank:Amount("reservedK"), 100)
end)

Cases.Case("a session refuses a forged system or transaction op", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("forgeK", { Gold = 100 })

	local Active = Bank:Session("forgeK")
	local System = Active:CommitOp({ Id = "forge1", Kind = "__TransferDeliver", Tid = "x", Amount = 1000000 } :: any):Wait()
	local Marked = Active:CommitOp({ Id = "forge2", Kind = "Fund", Amount = 5, Tx = "hax" } :: any):Wait()
	Active:Flush():Wait()

	T:Is("committing a forged system op", System, false)
	T:Is("committing an op that claims to be part of a transaction", Marked, false)
	T:Is("ops left on the key", #Bank:Record("forgeK").Ops, 0)
	T:Is("gold on disk", Bank:Amount("forgeK"), 100)
end)

Cases.Case("an op the datastore cannot hold is refused", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("escapeK", { Gold = 100 })

	local Active = Bank:Session("escapeK")
	local Ok, Why = Active:Apply("Fund", { Amount = 1, Blob = string.rep("\1", 300000) })

	T:Is("applying an op carrying bytes a datastore cannot hold", Ok, false)
	T:Is("the reason", Why, "Invalid")
	T:Is("gold the session reports", Active:Get().Gold, 100)
end)

Cases.Case("an oversized op is refused", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("bigK", { Gold = 100 })

	local Active = Bank:Session("bigK")
	local Ok = Active:Apply("Fund", { Amount = 1, Pad = Filler(200000) })

	T:Is("applying an op larger than the op cap", Ok, false)
	T:Is("gold the session reports", Active:Get().Gold, 100)
end)

Cases.Case("the unsaved backlog stops accepting ops", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("backlogK", { Gold = 100 })

	local Active = Bank:Session("backlogK")
	local Pad = Filler(12000)
	local Accepted = 0
	local Refused = false

	for _ = 1, 40 do
		if Active:Apply("Fund", { Amount = 1, Pad = Pad }) then
			Accepted += 1
		else
			Refused = true
			break
		end
	end

	T:Is("the backlog eventually refused an op", Refused, true)
	T:Is("some ops were accepted first", Accepted > 0, true)
	T:Is("the backlog did not accept all forty", Accepted < 40, true)
end)

Cases.Case("a backlog refusal and an invalid op read differently", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("reasonsK", { Gold = 0 })

	local Active = Bank:Session("reasonsK")
	local Junk, JunkWhy = Active:Apply("Fund", { Amount = 0 / 0 })

	local Big = string.rep("x", 64 * 1024)
	local Landed, LandedWhy = false, nil :: any
	for _ = 1, 40 do
		Landed, LandedWhy = Active:Apply("Fund", { Amount = 1, Pad = Big })
		if not Landed then
			break
		end
	end

	T:Is("applying an op carrying nan", Junk, false)
	T:Is("the reason junk gives", JunkWhy, "Invalid")
	T:Is("the op that filled the backlog", Landed, false)
	T:Is("the reason a full backlog gives", LandedWhy, "Backlog")
end)

Cases.Case("Apply answers refused when the reducer refuses", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("refusedK", { Gold = 0 })

	local Active = Bank:Session("refusedK")
	local Funded, FundedWhy = Active:Apply("Fund", { Amount = 10 })
	local Short, ShortWhy = Active:Apply("Give", { Amount = -999 })

	T:Is("an apply the reducer takes", Funded, true)
	T:Is("the reason it gives", FundedWhy, nil)
	T:Is("an apply the reducer refuses", Short, false)
	T:Is("the reason a refusal gives", ShortWhy, "Refused")
end)

Cases.Case("Commit carries the same reasons as Apply", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("commitreasonK", { Gold = 0 })

	local Active = Bank:Session("commitreasonK")
	local Granted, GrantedWhy = Active:Commit("Fund", { Amount = 25 }):Wait()
	local Short, ShortWhy = Active:Commit("Give", { Amount = -999 }):Wait()

	Active:Release():Wait()
	local Closed, ClosedWhy = Active:Commit("Fund", { Amount = 1 }):Wait()

	T:Is("a commit the reducer takes", Granted, true)
	T:Is("the reason it gives", GrantedWhy, nil)
	T:Is("a commit the reducer refuses", Short, false)
	T:Is("the reason a refusal gives", ShortWhy, "Refused")
	T:Is("a commit after release", Closed, false)
	T:Is("the reason a closed session gives", ClosedWhy, "Closed")
end)

Cases.Case("a listener dropped mid push is not called anyway", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("dropK", { Gold = 0 })

	local Active = Bank:Session("dropK")
	local Watching = Active:Observe()
	local Links: { any } = {}
	local Stale, Calls = 0, 0
	local Cut = false

	for _ = 1, 5 do
		local Me: any
		Me = Watching:Subscribe(function()
			Calls += 1
			if not Me.Connected then
				Stale += 1
			end
			if not Cut then
				Cut = true
				for _, Other in Links do
					if Other ~= Me then
						Other:Disconnect()
					end
				end
			end
		end)
		table.insert(Links, Me)
	end

	Active:Apply("Fund", { Amount = 1 })

	T:Is("the first listener ran", Calls > 0, true)
	T:Is("listeners called after they were disconnected", Stale, 0)
	T:Is("listeners still connected once the push ended", Calls, 1)
end)

Cases.Case("a write names the key it landed on as stale", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 100, Touches = 0 })
	Bank:Seed("b", { Gold = 0, Touches = 0 })

	local Heard: { string } = {}
	local Link = Bank.Store:Stale():Subscribe(function(Key: string)
		table.insert(Heard, Key)
	end)

	Bank.Store:Edit("a", "Fund", { Amount = 5 }):Wait()
	T:Is("an edit that landed", table.concat(Heard, ","), "a")

	table.clear(Heard)
	Bank.Store:Edit("a", "Give", { Amount = -100000 }):Wait()
	T:Is("keys named by an edit the reducer refused", #Heard, 0)

	table.clear(Heard)
	Bank.Store:Transfer("a", "b", 5):Wait()
	table.sort(Heard)
	T:Is("keys named by a transfer", table.concat(Heard, ","), "a,b")

	table.clear(Heard)
	Bank.Store:Tx("deal", {
		{ Key = "a", Kind = "Give", Fields = { Amount = -5 } },
		{ Key = "b", Kind = "Fund", Fields = { Amount = 5 } }
	}):Wait()
	table.sort(Heard)
	T:Is("keys named by a transaction", table.concat(Heard, ","), "a,b")

	Link:Disconnect()
	table.clear(Heard)
	Bank.Store:Edit("a", "Fund", { Amount = 1 }):Wait()
	T:Is("keys named once the listener is gone", #Heard, 0)
end)

Cases.Case("a stale listener may yield and does not hold up the write", function(T: Case)
	T:Slow()

	local Bank = T:Bank()
	Bank:Seed("a", { Gold = 0, Touches = 0 })

	local Woke = false
	local Finished = false
	Bank.Store:Stale():Subscribe(function()
		task.wait(0.2)
		Woke = true
	end)

	local Started = os.clock()
	Bank.Store:Edit("a", "Fund", { Amount = 5 }):Wait()
	local Took = os.clock() - Started
	Finished = true

	T:Is("the write answered without waiting for the listener", Took < 0.15, true)
	T:Is("the listener had not finished yet", Woke, false)
	T:Silent("a yielding listener is not reported as an error", "Observer listener errored")

	local Stop = os.clock() + 5
	while not Woke and os.clock() < Stop do
		task.wait()
	end

	T:Is("the listener finished on its own thread", Woke, true)
	T:Is("the write had already returned", Finished, true)
	T:Is("gold the write landed", Bank:Amount("a"), 5)
end)

Cases.Case("every listener hears a push in the order they subscribed", function(T: Case)
	local Stream = Observer.New()
	local Heard: { number } = {}

	for Index = 1, 6 do
		Stream:Subscribe(function()
			table.insert(Heard, Index)
		end)
	end
	Stream:Push(1)

	T:Is("how many heard it", #Heard, 6)
	T:Is("the order they heard it in", table.concat(Heard, ","), "1,2,3,4,5,6")
end)

Cases.Case("a listener subscribing mid push does not hear that same value", function(T: Case)
	local Stream = Observer.New()
	local Late = 0

	Stream:Subscribe(function()
		Stream:Subscribe(function()
			Late += 1
		end)
	end)

	Stream:Push(1)
	local AfterFirst = Late
	Stream:Push(2)

	T:Is("a listener added while the value was going out", AfterFirst, 0)
	T:Is("the same listener on the next push", Late, 1)
end)

Cases.Case("a later listener dropped mid push does not cut the rest off", function(T: Case)
	local Stream = Observer.New()
	local Heard: { number } = {}
	local Links: { any } = {}

	Stream:Subscribe(function()
		Links[3]:Disconnect()
	end)

	for Index = 1, 4 do
		Links[Index] = Stream:Subscribe(function()
			table.insert(Heard, Index)
		end)
	end

	Stream:Push(1)

	T:Is("the listeners after the dropped one still heard it", table.concat(Heard, ","), "1,2,4")
end)

Cases.Case("an observer only sees real changes", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("observeK", { Gold = 10 })

	local Active = Bank:Session("observeK")
	local Seen: { number } = {}
	local Watching = Active:Observe()
		:Map(function(State: any): number
			return State.Gold
		end)
		:Changed()
		:Subscribe(function(Amount: number)
			table.insert(Seen, Amount)
		end)

	Active:Apply("Fund", { Amount = 5 })
	Active:Apply("Give", { Amount = -100 })
	Active:Apply("Fund", { Amount = 0 })
	Active:Apply("Fund", { Amount = 5 })

	Watching:Disconnect()
	Active:Apply("Fund", { Amount = 5 })

	T:Is("how many changes the observer saw", #Seen, 2)
	T:Is("the first change", Seen[1], 15)
	T:Is("the second change", Seen[2], 20)
	T:Is("gold once the observer is disconnected", Active:Get().Gold, 25)
end)

Cases.Case("a filtered observer drops what it does not want", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("filterK", { Gold = 0 })

	local Active = Bank:Session("filterK")
	local Rich = 0
	Active:Observe()
		:Filter(function(State: any): boolean
			return State.Gold >= 20
		end)
		:Subscribe(function()
			Rich += 1
		end)

	Active:Apply("Fund", { Amount = 5 })
	Active:Apply("Fund", { Amount = 5 })
	Active:Apply("Fund", { Amount = 15 })

	T:Is("how many times the filter let a state through", Rich, 1)
end)

Cases.Case("apply costs the same no matter how large the profile is", function(T: Case)
	local Bank = T:Store({ Default = Reducers.MONEY, Reducer = Ticker, Balance = "Gold" })
	local Applies = 150

	local function Cost(Key: string, Size: number): number
		Bank:Seed(Key, { Gold = 0, Touches = 0, Bag = Bag(Size) })
		local Active = Bank:Session(Key)

		local Started = os.clock()
		for _ = 1, Applies do
			Active:Apply("Tick")
		end
		return (os.clock() - Started) / Applies
	end

	local Small = Cost("costsmall", 0)
	local Large = Cost("costlarge", 2500)
	local Ratio = if Small > 0 then Large / Small else 0

	T:Is(`apply cost against profile size, {string.format("%.1fx", Ratio)}`, Ratio < 10, true)
end)

Cases.Case("a large profile still applies and reloads", function(T: Case)
	local Bank = T:Store({ Default = Reducers.MONEY, Reducer = Ticker, Balance = "Gold" })
	Bank:Seed("largeK", { Gold = 0, Touches = 0, Bag = Bag(2000) })

	local Active = Bank:Session("largeK")
	local Accepted = 0
	for _ = 1, 25 do
		if Active:Apply("Tick") then
			Accepted += 1
		end
	end
	Active:Flush():Wait()

	local Reloaded = Bank:Session("largeK")
	local State = Reloaded:Get()

	T:Is("how many applies landed", Accepted, 25)
	T:Is("gold the live session reports", Active:Get().Gold, 25)
	T:Is("gold a fresh session loads", State.Gold, 25)
	T:Is("the last item of the profile survived the round trip", State.Bag.item2000.Count, 2000)
end)

Cases.Case("a reducer that reads the clock is called out", function(T: Case)
	local function Impure(State: any, Op: any): any?
		if Op.Kind ~= "Fund" then
			return nil
		end
		return { Gold = State.Gold + Op.Amount, Touches = State.Touches, Stamp = os.clock() }
	end

	local Bank = T:Store({ Default = Reducers.MONEY, Reducer = Impure, Balance = "Gold" })
	Bank:Seed("impureK", { Gold = 0 })

	local Active = Bank:Session("impureK")
	Active:Apply("Fund", { Amount = 5 })
	Active:Flush():Wait()

	T:Warns("how many times an impure reducer was called out", "not deterministic", 1)
	T:Is("gold the session reports", Active:Get().Gold, 5)
end)

Cases.Case("a pure reducer is never called out", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("pureK", { Gold = 0 })

	local Active = Bank:Session("pureK")
	Active:Apply("Fund", { Amount = 5 })
	Active:Apply("Fund", { Amount = 7 })
	Active:Flush():Wait()
	Active:Apply("Fund", { Amount = 3 })
	Active:Flush():Wait()

	T:Silent("a pure reducer is never called out", "not deterministic")
	T:Is("gold the session reports", Active:Get().Gold, 15)
end)

Cases.Case("a destroyed store gives up its name and its sweeps", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("gonek", { Gold = 100 })

	local Name = Bank.Store.Options.Name
	local Shape = { Name = Name, Keys = "String", Default = { Gold = 0, Touches = 0 }, Reducer = Ticker }

	local Taken = pcall(Ledger.New, Shape)
	Bank.Store:Destroy()
	local Freed, Rebuilt = pcall(Ledger.New, Shape)

	local Used = pcall(function()
		Bank.Store:Peek("gonek"):Wait()
	end)
	local Again = pcall(function()
		Bank.Store:Destroy()
	end)

	T:Is("the name was taken while the store was alive", Taken, false)
	T:Is("the name is free once the store is destroyed", Freed, true)
	T:Is("reading through a destroyed store", Used, false)
	T:Is("destroying twice is harmless", Again, true)

	if Freed then
		Rebuilt:Destroy()
	end
end)

Cases.Case("loading onto a parked leg enlists the key for recovery", function(T: Case)
	local Store = T:Players()
	local Fake = T:Player(94)
	local Key = tostring(Fake.UserId)

	Store:Marker("join1", { Status = "Pending", Total = 2, Adopted = {} })
	Store:Park(Key, { Id = "tx:join1:1", Kind = "Fund", Amount = 5, Tx = "join1" })

	local Before = Registry.Sweep.Count
	Store.Store:Load(Fake)
	local After = Registry.Sweep.Count
	Store.Store:Unload(Fake)
	Registry.Sweep:Forget(Store.Store)

	T:Is("the leg is parked before the load", Store:Pending(Key), true)
	T:Is("the load enlisted the key for recovery", After - Before, 1)
end)

local function Stranded(T: Case): Fixture
	local Bank = T:Store({ Keys = "Player", Default = Reducers.MONEY, Reducer = Reducers.Banker, Balance = "Gold" })
	Bank:Seed("77", { Gold = 100, Touches = 0 })
	Bank:Seed("88", { Gold = 0, Touches = 0 })
	Bank:Append("77", {
		{ Id = "res:strand", Kind = "__TransferReserve", To = "88", Amount = 40, Tid = "strand", At = T:Now() } :: any
	})
	return Bank
end

Cases.Case("a player who leaves during the load still has their transfers picked up", function(T: Case)
	local Bank = Stranded(T)

	local Fake = T:Player(77)
	Fake.Parent = nil
	Bank.Store:Load(Fake)
	task.wait()

	T:Is("money still set aside on the key they left", Bank:Aside("77"), 0)
	T:Is("money the receiver got", Bank:Amount("88"), 40)
	T:Is("a session kept for a player who is not here", Bank.Store:IsLoaded(Fake), false)
end)

Cases.Case("a server on its way down does not start picking up transfers", function(T: Case)
	local Bank = Stranded(T)

	local Fake = T:Player(77)
	Registry.Shutting.Now = true
	Bank.Store:Load(Fake)
	Registry.Shutting.Now = false
	task.wait()

	T:Is("money left set aside for the next server", Bank:Aside("77"), 40)
	T:Is("money the receiver got while the server was closing", Bank:Amount("88"), 0)
	T:Is("a session kept while shutting down", Bank.Store:IsLoaded(Fake), false)
end)

Cases.Case("a second load while the first is still loading is ignored", function(T: Case)
	T:Slow()

	local Store = T:Players()
	local Fake = T:Player(91)

	local Done = false
	task.spawn(function()
		Store.Store:Load(Fake)
		Done = true
	end)
	Store.Store:Load(Fake)
	while not Done do
		task.wait()
	end

	T:Warns("the second load was ignored", "already loading", 1)
	T:Is("one session is live once the first lands", Store.Store:IsLoaded(Fake), true)
	Store.Store:Unload(Fake)
	T:Is("unloading cleans it up", Store.Store:IsLoaded(Fake), false)
end)

Cases.Case("an unload during a load releases the session on arrival", function(T: Case)
	T:Slow()

	local Store = T:Players()
	local Fake = T:Player(92)

	local Done = false
	task.spawn(function()
		Store.Store:Load(Fake)
		Done = true
	end)

	local Waited: any = "unset"
	task.spawn(function()
		Waited = Store.Store:WaitForLoaded(Fake)
	end)

	Store.Store:Unload(Fake)
	while not Done do
		task.wait()
	end

	T:Is("the waiter was woken with nothing", Waited, nil)
	T:Is("no session is live once the load lands", Store.Store:IsLoaded(Fake), false)

	Store.Store:Load(Fake)
	T:Is("the key is free for a fresh load", Store.Store:IsLoaded(Fake), true)
	Store.Store:Unload(Fake)
end)

Cases.Case("a rejoin during a leaving load ends with one live session", function(T: Case)
	T:Slow()

	local Store = T:Players()
	local Fake = T:Player(93)

	local Done = 0
	task.spawn(function()
		Store.Store:Load(Fake)
		Done += 1
	end)
	Store.Store:Unload(Fake)
	task.spawn(function()
		Store.Store:Load(Fake)
		Done += 1
	end)
	while Done < 2 do
		task.wait()
	end

	T:Silent("the rejoin was not ignored", "already loading")
	T:Warns("the duplicate was released", "loaded twice concurrently", 1)
	T:Is("one session is live", Store.Store:IsLoaded(Fake), true)
	Store.Store:Unload(Fake)
end)

Cases.Case("a failed load kicks and frees the key", function(T: Case)
	local Store = T:Players()
	local Fake = T:Player(94)

	Broke(Store, function()
		Store.Store:Load(Fake)
	end)

	T:Is("the player was kicked", Fake.Kicked, 1)
	T:Is("nothing is left live", Store.Store:IsLoaded(Fake), false)

	Store.Store:Load(Fake)
	T:Is("a later load is not blocked by the failed one", Store.Store:IsLoaded(Fake), true)
	Store.Store:Unload(Fake)
end)

Cases.Case("a load that fails hands the reason to the callback", function(T: Case)
	local Store, Fake, Seen = Failing(T, 95, function(): boolean
		return true
	end)

	Broke(Store, function()
		Store.Store:Load(Fake)
	end)

	T:Is("the callback was called once", #Seen, 1)
	T:Is("it was handed the player", if Seen[1] then Seen[1].Player else nil, Fake)
	T:Is("it was handed why the load failed", if Seen[1] then Seen[1].Why else nil, "Unresolved")
	T:Is("the player was left alone because it said it handled them", Fake.Kicked, 0)
	T:Is("nothing is left live", Store.Store:IsLoaded(Fake), false)

	Store.Store:Load(Fake)
	T:Is("a later load is not blocked by the failed one", Store.Store:IsLoaded(Fake), true)
	Store.Store:Unload(Fake)
end)

Cases.Case("a callback that says it did not handle the player still kicks", function(T: Case)
	local Store, Fake, Seen = Failing(T, 96, function(): boolean
		return false
	end)

	Broke(Store, function()
		Store.Store:Load(Fake)
	end)

	T:Is("the callback was called", #Seen, 1)
	T:Is("the player was kicked anyway", Fake.Kicked, 1)
	T:Is("nothing is left live", Store.Store:IsLoaded(Fake), false)
end)

Cases.Case("a callback that throws falls back to the kick", function(T: Case)
	local Store, Fake = Failing(T, 97, function(): boolean
		error("injected OnLoadFailed failure")
	end)

	Broke(Store, function()
		Store.Store:Load(Fake)
	end)

	T:Is("the player was kicked", Fake.Kicked, 1)
	T:Warns("it said the callback threw", "OnLoadFailed threw")
	T:Warns("it carried the cause", "injected OnLoadFailed failure")
end)

Cases.Case("waiters are let go before the callback is asked", function(T: Case)
	local Woke = false
	local WokeFirst = nil
	local Store, Fake = Failing(T, 98, function(): boolean
		WokeFirst = Woke
		task.wait(0.2)
		return true
	end)

	task.spawn(function()
		Store.Store:WaitForLoaded(Fake)
		Woke = true
	end)
	task.wait(0.05)

	Broke(Store, function()
		Store.Store:Load(Fake)
	end)

	T:Is("the waiter was let go before the callback was asked", WokeFirst, true)
	T:Is("the waiter did not come back holding a session", Store.Store:IsLoaded(Fake), false)
end)

Cases.Case("a load that lands after Destroy is let go of", function(T: Case)
	T:Slow()

	local Store = T:Players()
	local Fake = T:Player(97)

	local Done = false
	task.spawn(function()
		Store.Store:Load(Fake)
		Done = true
	end)

	Store.Store:Destroy()
	while not Done do
		task.wait()
	end

	local Held = 0
	for _ in Store.Store.Loaded do
		Held += 1
	end

	T:Is("sessions left on the destroyed store", Held, 0)
	T:Is("the player was not kicked, their data was just saved", Fake.Kicked, 0)
end)

Cases.Case("a commit refused at its landed position leaves nothing in the log", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("raced", { Gold = 100 })

	local Active: any = Session.Load(Bank:Log(), Bank:Format(), "raced"):Wait()

	Bank.Store:Edit("raced", "Give", { Amount = -100 }):Wait()

	local Ok, Why = Active:CommitOp({ Id = "raced1", Kind = "Give", Amount = -100 } :: any):Wait()

	local Stranded = false
	for _, Op in Bank:Record("raced").Ops do
		if Op.Id == "raced1" then
			Stranded = true
		end
	end

	Bank:Log():Compact("raced", Bank:Format())

	T:Is("the commit", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("the refused op being left in the log", Stranded, false)
	T:Is("ops still held back after a compaction", #Bank:Record("raced").Ops, 0)
	T:Is("gold once the race is over", Bank:Amount("raced"), 0)
end)

Cases.Case("a commit is checked against a record that compacted back to the op count it loaded on", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("folded", { Gold = 100, Touches = 0 })

	local Active: any = Session.Load(Bank:Log(), Bank:Format(), "folded"):Wait()
	T:Is("the ops the session loaded on", Active.LogSize, 0)

	Bank.Store:Edit("folded", "Give", { Amount = -100 }):Wait()
	Bank:Log():Compact("folded", Bank:Format())
	T:Is("the ops on the record now", #Bank:Record("folded").Ops, 0)
	T:Is("gold on the record now", Bank:Amount("folded"), 0)

	local Ok, Why = Active:CommitOp({ Id = "folded1", Kind = "Give", Amount = -100 } :: any):Wait()

	local Stranded = false
	for _, Op in Bank:Record("folded").Ops do
		if Op.Id == "folded1" then
			Stranded = true
		end
	end

	Bank:Log():Compact("folded", Bank:Format())

	T:Is("the commit", Ok, false)
	T:Is("the reason", Why, "Refused")
	T:Is("the op the record cannot fold being left in the log", Stranded, false)
	T:Is("ops still held back after a compaction", #Bank:Record("folded").Ops, 0)
	T:Is("gold once the stale commit is over", Bank:Amount("folded"), 0)
	T:Silent("no warning that the key cannot be compacted", "cannot be compacted")
end)

Cases.Case("a session left behind by another server's compaction is not called an impure reducer", function(T: Case)
	local Bank = T:Bank()
	Bank:Seed("stale", { Gold = 100, Touches = 0 })

	local Active: any = Session.Load(Bank:Log(), Bank:Format(), "stale"):Wait()
	Active:Apply("Touch", {})
	Active:Flush():Wait()
	local Mine = Active:Get().Touches

	for Index = 1, 12 do
		Bank.Store:Edit("stale", "Touch", {}):Wait()
	end
	Bank:Log():Compact("stale", Bank:Format())

	T:Is("ops left for the stale session to see", #Bank:Record("stale").Ops, 0)
	T:Is("touches the stale session still holds", Mine, 1)

	Active:Flush():Wait()

	T:Is("touches once it catches up", Active:Get().Touches, 13)
	T:Silent("the reducer is pure, so nothing says otherwise", "is not deterministic")
end)

return Cases
